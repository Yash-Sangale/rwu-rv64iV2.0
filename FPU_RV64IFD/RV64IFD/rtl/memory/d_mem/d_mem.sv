// =============================================================================
// dmem.sv - Data Memory (D-MEM)
//
// Specification compliance (final_spec.pdf §2.4.2, §3.0.4):
//   - 64 KB read/write data RAM
//   - Base address: 0x0001_0000, top: 0x0001_FFFF
//     (spec §3.0.4: "D-MEM is a separate 64 KB block mapped at address range
//      0x0001_0000-0x0001_FFFF")
//   - Accessed exclusively via the dedicated D-Bus (Harvard Architecture)
//   - NOT part of the Wishbone peripheral bus
//   - Deterministic timing: single-cycle latency, independent of peripheral traffic
//   - 80 MHz operation target
//
// Design decisions:
//   - Storage is 64-bit (doubleword) wide - matches XLEN and the widest
//     RV64I store/load (SD/LD). Narrower accesses use byte-enable masking.
//   - Read is registered (synchronous): data appears one cycle after address.
//     This matches FPGA BRAM inference rules and 80 MHz pipeline timing.
//   - Byte-enable write: 8-bit SEL vector (one bit per byte lane) allows
//     byte (SB), halfword (SH), word (SW), and doubleword (SD) stores
//     without needing separate read-modify-write cycles.
//   - Write forwarding: if a read and write hit the same doubleword address
//     in the same cycle, the write data is forwarded directly to the read
//     output port, avoiding a stale-read hazard without pipeline stalls.
//   - Parity: even-parity stored per byte (8 bits per doubleword).
//     Parity is updated only for bytes covered by the active SEL mask.
//     A parity error on the read output asserts parity_err for one cycle.
//   - The D-Bus interface mirrors the Wishbone-style signalling used
//     elsewhere in the design (addr/we/sel/wdata/rdata/ack) but is a
//     direct point-to-point connection - no Wishbone arbitration occurs.
//
// Interface:
//   D-Bus (CPU load/store side) - standard Harvard data port
//   Debug port                  - read-only observation for JTAG/debug
//
// Parameters:
//   MEM_DEPTH   - number of 64-bit doublewords (default 8192 = 64 KB)
//   INIT_FILE   - optional hex file for simulation pre-load
//   FWD_EN      - 1=enable write→read forwarding, 0=no forwarding
//   PARITY_EN   - 1=enable parity checking, 0=disable
// =============================================================================


`ifndef D_MEM_SV
`define D_MEM_SV 

`timescale 1ns / 1ps

`include "isa_pkg.sv"
`include "mem_map_pkg.sv"

import isa_pkg::*;
import mem_map_pkg::*;

module d_mem #(
    parameter int unsigned MEM_DEPTH = mem_map_pkg::DMEM_DEPTH,
    parameter string       INIT_FILE = "",
    parameter bit          FWD_EN    = 1,
    parameter bit          PARITY_EN = 1
) (
    input logic clk,
    input logic rst_n,


    // D-Bus - CPU load/store port (Harvard, non-Wishbone)
    input logic              cs,    // chip select / transaction valid
    input logic              we,    // 1 = write, 0 = read
    input logic [  XLEN-1:0] addr,  // byte address
    input logic [XLEN/8-1:0] sel,   // byte enables (8 bits for 64-bit bus)
    input logic [  XLEN-1:0] wdata, // write data

    output logic [XLEN-1:0] rdata,      // read data (1 cycle latency)
    output logic            ack,        // transaction acknowledged
    output logic            parity_err, // parity mismatch on read


    // Debug / observation port (read-only, combinational - for JTAG/debug)
    input  logic [XLEN-1:0] dbg_addr,  // byte address to observe
    output logic [XLEN-1:0] dbg_rdata  // combinational read (no latency)
);

  localparam int ADDR_W = $clog2(MEM_DEPTH);
  localparam int NBYTES = XLEN / 8;


  // Memory
  logic [  XLEN-1:0] mem      [0:MEM_DEPTH-1];
  logic [NBYTES-1:0] mem_par  [0:MEM_DEPTH-1];

  logic              in_range;
  logic [ADDR_W-1:0] idx;

  assign in_range = in_dmem(addr);
  assign idx      = (addr - DMEM_BASE) >> 3;

  initial begin
    for (int i = 0; i < MEM_DEPTH; i++) begin
      mem[i]     = '0;
      mem_par[i] = '0;
    end

    if (INIT_FILE != "") begin
      $readmemh(INIT_FILE, mem);
      for (int i = 0; i < MEM_DEPTH; i++)
      for (int b = 0; b < NBYTES; b++) mem_par[i][b] = ^mem[i][8*b+:8];
    end
  end


  // MEMORY ACCESS
  logic [  XLEN-1:0] rdata_mem_q;
  logic [NBYTES-1:0] rpar_mem_q;
  logic              rd_valid_q;

  always_ff @(posedge clk) begin
    // WRITE
    if (cs && we && in_range) begin
      for (int b = 0; b < NBYTES; b++) begin
        if (sel[b]) begin
          mem[idx][8*b+:8] <= wdata[8*b+:8];
          mem_par[idx][b]  <= ^wdata[8*b+:8];
        end
      end
    end

    // READ
    if (cs && !we && in_range) begin
      rdata_mem_q <= mem[idx];
      rpar_mem_q  <= mem_par[idx];
    end

    rd_valid_q <= cs && !we && in_range;
  end

  // Capture write info (aligned stage)
  logic              wr_d;
  logic [ADDR_W-1:0] wr_idx_d;
  logic [  XLEN-1:0] wdata_d;
  logic [NBYTES-1:0] sel_d;

  always_ff @(posedge clk) begin
    wr_d     <= cs && we && in_range;
    wr_idx_d <= idx;
    wdata_d  <= wdata;
    sel_d    <= sel;
  end

  // FORWARD + PARITY + OUTPUT
  logic [XLEN-1:0] rdata_fwd;
  logic fwd_hit;

  assign fwd_hit = FWD_EN && wr_d && (wr_idx_d == idx);

  always_comb begin
    rdata_fwd = rdata_mem_q;
    if (fwd_hit) begin
      for (int b = 0; b < NBYTES; b++) begin
        if (sel_d[b]) rdata_fwd[8*b+:8] = wdata_d[8*b+:8];
      end
    end
  end

  // Parity
  logic [NBYTES-1:0] computed_par;

  for (genvar b = 0; b < NBYTES; b++) begin
    assign computed_par[b] = ^rdata_mem_q[8*b+:8];
  end

  assign parity_err = PARITY_EN ? (rd_valid_q && (computed_par != rpar_mem_q)) : 1'b0;

  // ACK (1-cycle delayed) per transcation 1 ack
  logic req_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) req_r <= 0;
    else req_r <= cs && in_range;
  end

  // @NOTE: If single-pulse ack per transaction is a hard requirement, the pipeline calling it must handle deassert of cs — that's the CPU's responsibility, not dmem's.
  assign ack   = req_r;

  // Output
  assign rdata = rdata_fwd;

  // Debug
  logic [ADDR_W-1:0] dbg_idx;
  assign dbg_idx   = (dbg_addr - DMEM_BASE) >> 3;
  assign dbg_rdata = mem[dbg_idx];

  always @(posedge clk) begin
    if (cs && !(addr >= DMEM_BASE && addr <= DMEM_END)) $display("[DMEM] WARNING addr=0x%h", addr);

    if (PARITY_EN && rd_valid_q && (computed_par != rpar_mem_q))
      $display("[DMEM] PARITY ERROR idx=%0d", idx);
  end


  // synthesis translate_off
  task automatic dbg_corrupt_parity(input logic [ADDR_W-1:0] idx);
    $display("BEFORE: %b", mem_par[idx]);
    mem_par[idx] = ~mem_par[idx];
    $display("AFTER : %b", mem_par[idx]);
    $display("[DMEM-DEBUG] Corrupted parity at idx=%0d", idx);
  endtask

  task automatic dbg_write_raw(input logic [ADDR_W-1:0] idx, input logic [XLEN-1:0] data);
    mem[idx] = data;
    $display("[DMEM-DEBUG] Raw write at idx=%0d data=0x%h", idx, data);
  endtask
  // synthesis translate_on

endmodule

`endif
