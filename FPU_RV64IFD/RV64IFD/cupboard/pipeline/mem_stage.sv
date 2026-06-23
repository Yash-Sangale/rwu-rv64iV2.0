`timescale 1ns/1ps

`ifndef MEM_STAGE_SV
`define MEM_STAGE_SV

`include "isa_pkg.sv"
`include "types_pkg.sv"
`include "wb_pkg.sv"
`include "mem_map_pkg.sv"

import isa_pkg::*;
import types_pkg::*;
import wb_pkg::*;
import mem_map_pkg::*;

// MEM stage — address-based routing (DMEM Harvard or WB peripheral).
//
// FP loads  (fp_load=1):  normal load path; wb_stage routes result to fp regfile.
// FP stores (fp_store=1): store data comes from ex_mem.fp_rs2_val instead of rs2_val.
// All other ops: pass-through to WB stage.
//
// Stall: held while active_access && !ack_combined.
module mem_stage (
    input  logic clk,
    input  logic rst_n,

    input  ex_mem_reg_t  ex_mem,
    output mem_wb_reg_t  mem_wb_next,

    output logic stall,

    output logic            dmem_cs,
    output logic            dmem_we,
    output logic [XLEN-1:0] dmem_addr,
    output logic [7:0]      dmem_sel,
    output logic [XLEN-1:0] dmem_wdata,
    input  logic [XLEN-1:0] dmem_rdata,
    input  logic            dmem_ack,

    output wb_req_t  wb_req,
    input  wb_resp_t wb_resp
);

  logic is_load, is_store, is_mem_op;
  logic is_dmem_r, is_periph_r;

  assign is_load   = ex_mem.dec.mem_read;
  assign is_store  = ex_mem.dec.mem_write;
  assign is_mem_op = ex_mem.valid && (is_load || is_store);

  assign is_dmem_r  = is_mem_op && in_dmem(ex_mem.alu_fpu_result);
  assign is_periph_r = is_mem_op && in_periph(ex_mem.alu_fpu_result);

  // Byte select
  function automatic logic [7:0] funct3_sel(
      input logic [2:0] f3, input logic [2:0] lsb);
    unique case (f3)
      3'b000, 3'b100: return 8'b0000_0001 << lsb;
      3'b001, 3'b101: return 8'b0000_0011 << {lsb[2:1], 1'b0};
      3'b010, 3'b110: return 8'b0000_1111 << {lsb[2], 2'b00};
      3'b011:         return 8'b1111_1111;
      default:        return 8'b0;
    endcase
  endfunction

  // FP store: funct3 encodes width (2=word/FSW, 3=double/FSD), byte select same as integer
  logic [7:0] byte_sel;
  assign byte_sel = funct3_sel(ex_mem.dec.funct3, ex_mem.alu_fpu_result[2:0]);

  // Store data source: fp_store uses fp_rs2_val, integer store uses rs2_val
  logic [XLEN-1:0] store_data;
  assign store_data = ex_mem.dec.fp_store ? ex_mem.fp_rs2_val : ex_mem.rs2_val;

  // DMEM port
  assign dmem_cs    = is_dmem_r;
  assign dmem_we    = is_dmem_r && is_store;
  assign dmem_addr  = ex_mem.alu_fpu_result;
  assign dmem_sel   = byte_sel;
  assign dmem_wdata = store_data;

  // WB peripheral port
  always_comb begin
    wb_req = WB_REQ_IDLE;
    if (is_periph_r) begin
      wb_req.cyc = 1'b1;
      wb_req.stb = 1'b1;
      wb_req.we  = is_store;
      wb_req.adr = ex_mem.alu_fpu_result;
      wb_req.dat = store_data;
      wb_req.sel = byte_sel;
    end
  end

  logic ack_combined;
  assign ack_combined = (is_dmem_r   && dmem_ack)  ||
                        (is_periph_r && wb_resp.ack);
  assign stall = is_mem_op && !ack_combined;

  // Read data mux
  logic [XLEN-1:0] raw_rdata;
  assign raw_rdata = is_dmem_r ? dmem_rdata : wb_resp.dat;

  // Load sign/zero extension
  logic [XLEN-1:0] load_data;
  always_comb begin
    logic [7:0]  bl;
    logic [15:0] hl;
    logic [31:0] wl;
    bl = raw_rdata >> ({ex_mem.alu_fpu_result[2:0], 3'b0});
    hl = raw_rdata >> ({ex_mem.alu_fpu_result[2:1], 4'b0});
    wl = raw_rdata >> ({ex_mem.alu_fpu_result[2],   5'b0});
    unique case (ex_mem.dec.funct3)
      3'b000: load_data = {{56{bl[7]}},  bl};
      3'b001: load_data = {{48{hl[15]}}, hl};
      3'b010: load_data = {{32{wl[31]}}, wl};
      3'b011: load_data = raw_rdata;
      3'b100: load_data = {56'b0, bl};
      3'b101: load_data = {48'b0, hl};
      3'b110: load_data = {32'b0, wl};
      default: load_data = raw_rdata;
    endcase
  end

  // FLD result: NaN-box single if funct3==2 (FLW loads 32-bit → NaN-box to 64)
  // FLD (funct3==3) is already full 64-bit, no boxing needed.
  logic [XLEN-1:0] fp_load_data;
  always_comb begin
    if (ex_mem.dec.funct3 == 3'b010)  // FLW: NaN-box upper 32 bits
      fp_load_data = {32'hFFFF_FFFF, load_data[31:0]};
    else
      fp_load_data = load_data;  // FLD: pass through
  end

  always_comb begin
    mem_wb_next.dec              = ex_mem.dec;
    mem_wb_next.alu_fpu_result   = ex_mem.alu_fpu_result;
    mem_wb_next.fp_to_int        = ex_mem.fp_to_int;
    mem_wb_next.fp_fflags        = ex_mem.fp_fflags;
    mem_wb_next.addr_misaligned  = ex_mem.addr_misaligned;
    // FP loads use fp_load_data; integer loads use load_data
    mem_wb_next.mem_rdata        = ex_mem.dec.fp_load ? fp_load_data : load_data;
    mem_wb_next.wb_data          = '0;
    mem_wb_next.valid            = ex_mem.valid && !stall;
  end

endmodule

`endif
