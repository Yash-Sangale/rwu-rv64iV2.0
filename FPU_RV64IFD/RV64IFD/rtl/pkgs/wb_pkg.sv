`timescale 1ns/1ps

`ifndef WB_PKG_SV
`define WB_PKG_SV

`include "isa_pkg.sv"
`include "mem_map_pkg.sv"

// =============================================================================
// wb_pkg.sv — on-chip bus definitions
//
// Defines the internal bus protocol used between the core, memories,
// and peripherals.  Currently a simplified Wishbone B4 single-master style.
//
// Why Wishbone-inspired:
//   - Open standard, no licence
//   - Directly supported by many open-source peripherals (wb_uart, etc.)
//   - Simple to bridge to AXI4-Lite when needed for Vivado IP
//
// Current topology: single master (core) → simple decode → slaves
//
//   core
//    └─ wb_master_t ──► address decoder (top.sv)
//                           ├──► IMEM  (wb_slave_t)
//                           ├──► DMEM  (wb_slave_t)
//                           ├──► UART0 (wb_slave_t)
//                           └──► GPIO0 (wb_slave_t)
//
// Extension guide:
//   Multi-core → promote to shared crossbar: wb_crossbar.sv
//   AXI IP     → add wb_to_axi_bridge.sv
//   DMA        → add second wb_master_t from DMA engine
//   Cache      → insert cache between core and bus, same interface
//
// Signal naming follows Wishbone B4 spec (simplified):
//   CYC  — bus cycle active
//   STB  — valid transfer on this cycle
//   WE   — write enable (1=write, 0=read)
//   ADR  — byte address
//   DAT  — data (separate master→slave and slave→master)
//   SEL  — byte select (one bit per byte lane)
//   ACK  — slave acknowledges transfer
//   ERR  — slave signals bus error (address decode failure)
//   STALL— slave not ready (pipeline stall — used in pipelined mode)
// =============================================================================

package wb_pkg;

  import isa_pkg::XLEN;
  import mem_map_pkg::addr_t;

  // -------------------------------------------------------------------------
  // Bus width parameters
  // DATA_W and ADDR_W are separate so a future 32-bit peripheral bus
  // can reuse the same structs with different parameters.
  // -------------------------------------------------------------------------
  parameter int unsigned WB_DATA_W = XLEN;        // 64-bit data bus
  parameter int unsigned WB_ADDR_W = XLEN;        // 64-bit address bus
  parameter int unsigned WB_SEL_W  = WB_DATA_W/8; // 8 byte-select bits

  // -------------------------------------------------------------------------
  // Master → Slave request
  // Driven by the bus master (core, DMA) toward a slave.
  // -------------------------------------------------------------------------
  typedef struct packed {
    logic                    cyc;    // bus cycle valid
    logic                    stb;    // transfer strobe (cyc & stb = active xfer)
    logic                    we;     // 1 = write, 0 = read
    logic [WB_ADDR_W-1:0]    adr;    // byte address
    logic [WB_DATA_W-1:0]    dat;    // write data (ignored on reads)
    logic [WB_SEL_W-1:0]     sel;    // byte enables (1 bit per byte lane)
  } wb_req_t;

  // -------------------------------------------------------------------------
  // Slave → Master response
  // Driven by the addressed slave back to the master.
  // -------------------------------------------------------------------------
  typedef struct packed {
    logic [WB_DATA_W-1:0]    dat;    // read data (valid when ack=1 on a read)
    logic                    ack;    // transfer acknowledged
    logic                    err;    // bus error (unmapped address, misalign)
    logic                    stall;  // slave not ready (hold req stable)
  } wb_resp_t;

  // -------------------------------------------------------------------------
  // Convenience: null/idle values
  // Assign these to unused ports to silence undriven-signal warnings.
  // -------------------------------------------------------------------------
  parameter wb_req_t  WB_REQ_IDLE  = '{cyc:0, stb:0, we:0,
                                        adr:'0, dat:'0, sel:'0};
  parameter wb_resp_t WB_RESP_IDLE = '{dat:'0, ack:0, err:0, stall:0};
  parameter wb_resp_t WB_RESP_ERR  = '{dat:'0, ack:0, err:1, stall:0};

  // -------------------------------------------------------------------------
  // Byte-select helpers
  // Generate the correct sel field from an address and access width.
  // These match the funct3 width encoding in RISC-V load/store instructions.
  // -------------------------------------------------------------------------

  // Access width codes (map directly from funct3[1:0])
  typedef enum logic [1:0] {
    WB_WIDTH_BYTE   = 2'b00,   // 1 byte  (LB/SB)
    WB_WIDTH_HALF   = 2'b01,   // 2 bytes (LH/SH)
    WB_WIDTH_WORD   = 2'b10,   // 4 bytes (LW/SW)
    WB_WIDTH_DOUBLE = 2'b11    // 8 bytes (LD/SD)
  } wb_width_t;

  // Generate byte-select mask from byte address and width
  // addr[2:0] = byte offset within the 8-byte doubleword
  function automatic logic [WB_SEL_W-1:0] wb_byte_sel(
    input logic [2:0]  byte_offset,
    input wb_width_t   width
  );
    logic [WB_SEL_W-1:0] sel;
    sel = '0;
    unique case (width)
      WB_WIDTH_BYTE:   sel = 8'b0000_0001 << byte_offset;
      WB_WIDTH_HALF:   sel = 8'b0000_0011 << {byte_offset[2:1], 1'b0};
      WB_WIDTH_WORD:   sel = 8'b0000_1111 << {byte_offset[2], 2'b00};
      WB_WIDTH_DOUBLE: sel = 8'b1111_1111;
    endcase
    return sel;
  endfunction

  // -------------------------------------------------------------------------
  // Wishbone classic vs pipelined mode flag
  // Set to 1 in top.sv if all slaves support pipelined mode (stall signal).
  // -------------------------------------------------------------------------
  parameter logic WB_PIPELINED = 1'b0;  // classic (ACK same or next cycle)

  typedef enum logic [2:0] {
    WB_SLAVE_NONE = 3'd0,
    WB_SLAVE_UART = 3'd1,
    WB_SLAVE_GPIO = 3'd2,
    WB_SLAVE_QSPI = 3'd3,
    WB_SLAVE_IRQ  = 3'd4,
    WB_SLAVE_CLK  = 3'd5,
    WB_SLAVE_JTAG = 3'd6
} wb_slave_sel_t;

endpackage

`endif // WB_PKG_SV
