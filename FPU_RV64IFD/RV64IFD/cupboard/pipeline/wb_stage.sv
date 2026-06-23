`timescale 1ns / 1ps

`ifndef WB_STAGE_SV
`define WB_STAGE_SV

`include "isa_pkg.sv"
`include "types_pkg.sv"

import isa_pkg::*;
import types_pkg::*;

// WB stage — writeback to integer or FP register file.
//
// Integer RF write conditions:
//   - Standard ALU/load result:  is_fp=0, reg_write=1
//   - FP-to-int result:          is_fp=1, fp_to_int=1  (FCMP, FCVT float→int,
//                                                        FMV.X.*, FCLASS)
//
// FP RF write conditions:
//   - FP arithmetic result:      is_fp=1, fp_to_int=0, fp_load=0
//   - FP load result (FLD/FLW):  is_fp=1, fp_load=1
//
// fflags accumulation:
//   The WB stage exposes fp_fflags for the CSR regfile to latch into fcsr.fflags.
//   Accumulation (OR into fflags register) happens in csr_regfile on fp_commit.
module wb_stage (
    input  logic clk,
    input  logic rst_n,

    input  mem_wb_reg_t mem_wb,

    // Integer register file
    output logic                       rf_we,
    output logic [REG_ADDRESS_LEN-1:0] rf_waddr,
    output logic [XLEN-1:0]            rf_wdata,

    // FP register file
    output logic                       frf_we,
    output logic [REG_ADDRESS_LEN-1:0] frf_waddr,
    output logic [FLEN-1:0]            frf_wdata,

    // FP exception flags → csr_regfile
    output logic [4:0]  fp_fflags_out,
    output logic        fp_commit        // pulse: valid FP instruction committed
);

  logic [XLEN-1:0] wb_data;

  always_comb begin
    wb_data = mem_wb.alu_fpu_result;
    if (mem_wb.dec.mem_read)
      wb_data = mem_wb.mem_rdata;
  end

  // Integer RF: normal ops + fp-to-int results
  assign rf_we    = mem_wb.valid
                    && mem_wb.dec.reg_write
                    && (!mem_wb.dec.is_fp || mem_wb.fp_to_int)
                    && !mem_wb.dec.fp_load
                    && (mem_wb.dec.rd != 5'd0);
  assign rf_waddr = mem_wb.dec.rd;
  assign rf_wdata = wb_data;

  // FP RF: FP arithmetic results + FP loads (FLD/FLW)
  assign frf_we    = mem_wb.valid
                     && mem_wb.dec.is_fp
                     && !mem_wb.fp_to_int
                     && mem_wb.dec.reg_write
                     && (mem_wb.dec.rd != 5'd0);
  assign frf_waddr = mem_wb.dec.rd;
  // FLD/FLW result comes from mem_rdata (already NaN-boxed in mem_stage)
  assign frf_wdata = mem_wb.dec.fp_load ? mem_wb.mem_rdata : wb_data;

  // fflags: exported to csr_regfile for accumulation into fcsr
  assign fp_fflags_out = mem_wb.fp_fflags;
  assign fp_commit     = mem_wb.valid && mem_wb.dec.is_fp && !mem_wb.dec.fp_load
                         && !mem_wb.dec.fp_store;

endmodule

`endif
