// =============================================================================
// imem.sv — Instruction Memory (I-MEM)
//
// Specification compliance (final_spec.pdf §2.4.2, §3.0.4):
//   - 64 KB read-only program memory, word-addressed
//   - Base address: 0x0000_0000, top: 0x0000_FFFF
//   - Accessed exclusively via the dedicated I-Bus (Harvard Architecture)
//   - NOT connected to the Wishbone peripheral bus
//   - Single-cycle read latency (no wait states in nominal operation)
//   - 80 MHz operation target
//
// Design decisions:
//   - Storage is 32-bit wide (one word per address) — matches ILEN=32
//   - Address input is the full 64-bit PC; only [15:2] indexes the array
//     (bits [1:0] are the intra-word offset; the CPU must always fetch
//      word-aligned addresses — misalignment triggers an exception upstream)
//   - Read is registered (synchronous): read data appears one cycle after
//     the address is presented. This is industry-standard for FPGA BRAM
//     inference and matches the timing of the 80 MHz pipeline.
//   - Parity: one even-parity bit stored per byte (4 bits per word).
//     On a parity error, parity_err is asserted for one cycle.
//     Parity computation is done at write time (initialisation / JTAG load).
//   - JTAG load port: a write-enable backdoor used during simulation and
//     FPGA programming.  In synthesis the JTAG TAP controller drives this.
//     $readmemh is also supported for simulation pre-load.
//   - Output valid: imem_valid is asserted the cycle after a valid address
//     is presented with cs asserted.
//
// Interface:
//   I-Bus (CPU fetch side)  — standard Harvard fetch port
//   JTAG load side          — word-write port for programming
//
// Parameters:
//   MEM_DEPTH   — number of 32-bit words (default 16384 = 64 KB)
//   INIT_FILE   — optional hex file loaded at elaboration time
//   PARITY_EN   — 1=enable parity checking, 0=disable (saves area)
// =============================================================================

`ifndef IMEM_SV
`define IMEM_SV

`timescale 1ns/1ps

`include "isa_pkg.sv"
`include "mem_map_pkg.sv"

import isa_pkg::*;
import mem_map_pkg::*;

module i_mem #(
    parameter int unsigned MEM_DEPTH  = mem_map_pkg::IMEM_DEPTH,  // 16384 words = 64 KB
    parameter string       INIT_FILE  = "",   // optional $readmemh file
    parameter bit          PARITY_EN  = 1     // 1 = enable parity
) (
    input  logic                    clk,
    input  logic                    rst_n,

    
    // I-Bus — CPU instruction fetch port (Harvard)
    
    input  logic                    cs,         // chip select (fetch valid)
    input  logic [XLEN-1:0]         addr,       // byte address from PC
    output logic [ILEN-1:0]         rdata,      // instruction word (1 cycle latency)
    output logic                    valid,      // rdata is valid this cycle
    output logic                    parity_err, // parity mismatch detected

    
    // JTAG / debug load port — write-only, used during programming
    
    input  logic                    jtag_we,    // JTAG write enable
    input  logic [XLEN-1:0]         jtag_addr,  // byte address
    input  logic [ILEN-1:0]         jtag_wdata  // word to write
);

  
  // Local parameters
  
  localparam int unsigned ADDR_W = $clog2(MEM_DEPTH);  // word-address width

  
  // Memory array
  // [ILEN-1:0] = 32 data bits
  // [4:0]      = 4 parity bits (one per byte), 1 spare
  // Stored separately so tools infer clean BRAM for the data portion.
  
  logic [ILEN-1:0]   mem      [0:MEM_DEPTH-1];
  logic [3:0]        mem_par  [0:MEM_DEPTH-1];  // even parity per byte

  
  // Optional initialisation from file
  
  initial begin
    // Zero the array first — guarantees deterministic reset in simulation
    for (int i = 0; i < MEM_DEPTH; i++) begin
      mem    [i] = '0;
      mem_par[i] = '0;
    end
    if (INIT_FILE != "") begin
      $readmemh(INIT_FILE, mem);
      $display("[IMEM] Loaded: %s", INIT_FILE);
      // Recompute parity for all loaded words
      for (int i = 0; i < MEM_DEPTH; i++) begin
        mem_par[i][0] = ^mem[i][ 7: 0];
        mem_par[i][1] = ^mem[i][15: 8];
        mem_par[i][2] = ^mem[i][23:16];
        mem_par[i][3] = ^mem[i][31:24];
      end
    end
  end

  
  // Address decode — strip byte offset, compute word index
  // addr[1:0] must be 2'b00; a non-zero value is a fetch misalignment.
  // That check is the CPU's responsibility; IMEM just ignores the low bits.
  
  logic [ADDR_W-1:0] word_idx;
  logic [ADDR_W-1:0] jtag_word_idx;
  logic              addr_in_range;

  assign word_idx      = addr[ADDR_W+1:2];           // PC bits [N+1:2]
  assign jtag_word_idx = jtag_addr[ADDR_W+1:2];
  assign addr_in_range = (addr >= IMEM_BASE) && (addr <= IMEM_END);

  
  // JTAG write (highest priority — overrides reads)
  // Parity is computed and stored alongside the data.
  
  always_ff @(posedge clk) begin
    if (jtag_we) begin
      mem    [jtag_word_idx]    <= jtag_wdata;
      mem_par[jtag_word_idx][0] <= ^jtag_wdata[ 7: 0];
      mem_par[jtag_word_idx][1] <= ^jtag_wdata[15: 8];
      mem_par[jtag_word_idx][2] <= ^jtag_wdata[23:16];
      mem_par[jtag_word_idx][3] <= ^jtag_wdata[31:24];
    end
  end

  
  // Synchronous read — registered output (BRAM style)
  
  logic [ILEN-1:0] rdata_r;
  logic [3:0]      rpar_r;
  logic            valid_r;
  logic            cs_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rdata_r <= '0;
      rpar_r  <= '0;
      valid_r <= 1'b0;
      cs_r    <= 1'b0;
    end else begin
      cs_r    <= cs & addr_in_range;
      valid_r <= cs & addr_in_range;
      if (cs & addr_in_range) begin
        rdata_r <= mem    [word_idx];
        rpar_r  <= mem_par[word_idx];
      end
    end
  end

  
  // Parity check — combinational, evaluated on the registered read output
  
  logic [3:0] computed_par;
  assign computed_par[0] = ^rdata_r[ 7: 0];
  assign computed_par[1] = ^rdata_r[15: 8];
  assign computed_par[2] = ^rdata_r[23:16];
  assign computed_par[3] = ^rdata_r[31:24];

  
  // Output assignments
  
  assign rdata      = rdata_r;
  assign valid      = valid_r;
  assign parity_err = PARITY_EN ? (valid_r & (computed_par != rpar_r)) : 1'b0;

  
  // Simulation assertions
  // synthesis translate_off
  always @(posedge clk) begin
    if (cs && !addr_in_range) begin
      $display("[IMEM] WARNING: fetch outside IMEM range: addr=0x%h at t=%0t", addr, $time);
    end
    if (cs && addr[1:0] != 2'b00) begin
      $display("[IMEM] WARNING: misaligned fetch addr=0x%h at t=%0t", addr, $time);
    end
    if (PARITY_EN && valid_r && (computed_par != rpar_r)) begin
      $display("[IMEM] PARITY ERROR at word_idx=%0d: stored_par=%b computed_par=%b at t=%0t",
               word_idx, rpar_r, computed_par, $time);
    end
  end

  task automatic dbg_corrupt_parity(input logic [ADDR_W-1:0] idx);
    mem_par[idx] = ~mem_par[idx];
    $display("[IMEM-DEBUG] Corrupted parity at idx=%0d", idx);
  endtask

  // synthesis translate_on

endmodule

`endif // IMEM_SV
