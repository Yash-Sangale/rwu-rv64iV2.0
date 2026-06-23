`timescale 1ns / 1ps

`ifndef FPU_TOP_SV
`define FPU_TOP_SV

`include "isa_pkg.sv"
`include "fpu_ctrl.sv"
`include "fpu_addsub.sv"
`include "fpu_mul.sv"
`include "fpu_div.sv"
`include "fpu_sqrt.sv"
`include "fpu_cmp.sv"
`include "fpu_cvt.sv"
`include "fpu_sign.sv"
`include "fpu_minmax.sv"
`include "fpu_mv.sv"
`include "fpu_classify.sv"
`include "fpu_cvt_fmt.sv"

import isa_pkg::*;

// fpu_top.sv — RV64FD FPU Top (extended for complete RV64FD coverage)
//
// Submodule map:
//   fpu_addsub  — FADD.S/D, FSUB.S/D
//   fpu_mul     — FMUL.S/D
//   fpu_div     — FDIV.S/D
//   fpu_sqrt    — FSQRT.S/D
//   fpu_cmp     — FEQ/FLT/FLE .S/D
//   fpu_cvt     — FCVT int↔float (all widths)
//   fpu_sign    — FSGNJ/FSGNJN/FSGNJX .S/D
//   fpu_minmax  — FMIN/FMAX .S/D
//   fpu_mv      — FMV.X.W/D, FMV.W/D.X
//   fpu_classify— FCLASS.S/D
//   fpu_cvt_fmt — FCVT.S.D, FCVT.D.S
//
// fp_fmt: FP_FMT_S (2'b00) or FP_FMT_D (2'b01) passed to each submodule.
// to_int: asserted when result must be written to integer regfile
//         (FCMP, FCVT float→int, FMV.X.*, FCLASS).
//
// @Note NaN boxing of single-precision results is handled inside each
//   submodule. fpu_top does not need to re-box.
// @Warning FLD/FSD do NOT go through the FPU — they use the standard
//   memory path. fp_load/fp_store flags in decoded_instr_t route them
//   to the fp regfile in id_stage and wb_stage respectively.
module fpu_top (
    input logic clk,
    input logic rst_n,

    input instruction_t            inst,
    input logic         [     4:0] fp_funct5,
    input logic         [     2:0] fp_rm,
    input logic                    fp_cvt_toint,
    input logic                    fp_cvt_word,
    input logic                    fp_cvt_signed,
    input logic         [     1:0] fp_fmt,
    input logic         [     1:0] fp_sgn_op,
    input logic                    fp_min_sel,
    input logic         [FLEN-1:0] operand_a,      // fp rs1
    input logic         [FLEN-1:0] operand_b,      // fp rs2
    input logic         [XLEN-1:0] int_operand,    // integer rs1 (for FMV.*.X)

    output logic [FLEN-1:0] result,
    output logic            to_int,
    output logic [     4:0] fflags,

    input  logic div_valid_in,
    output logic div_ready,
    output logic div_valid_out
);

  // Control unit
  logic addsub_en, addsub_sub;
  logic mul_en, div_en, sqrt_en;
  logic       cmp_en;
  logic [1:0] cmp_op;
  logic       cvt_en;
  logic sign_en, minmax_en, mv_en, class_en, cvtfmt_en;
  fpu_res_sel_t res_sel;

  fpu_ctrl u_ctrl (
      .inst      (inst),
      .fp_funct5 (fp_funct5),
      .fp_rm     (fp_rm),
      .addsub_en (addsub_en),
      .addsub_sub(addsub_sub),
      .mul_en    (mul_en),
      .div_en    (div_en),
      .sqrt_en   (sqrt_en),
      .cmp_en    (cmp_en),
      .cmp_op    (cmp_op),
      .cvt_en    (cvt_en),
      .sign_en   (sign_en),
      .minmax_en (minmax_en),
      .mv_en     (mv_en),
      .class_en  (class_en),
      .cvtfmt_en (cvtfmt_en),
      .res_sel   (res_sel)
  );

  // Arithmetic units — fp_fmt passed through for S/D dispatch
  logic [FLEN-1:0] addsub_r;
  logic [4:0] addsub_ff;
  fpu_addsub u_addsub (
      .en(addsub_en),
      .sub(addsub_sub),
      .fp_rm(fp_rm),
      .fp_fmt(fp_fmt),
      .operand_a(operand_a),
      .operand_b(operand_b),
      .result(addsub_r),
      .fflags(addsub_ff)
  );

  logic [FLEN-1:0] mul_r;
  logic [4:0] mul_ff;
  fpu_mul u_mul (
      .en(mul_en),
      .fp_rm(fp_rm),
      .fp_fmt(fp_fmt),
      .operand_a(operand_a),
      .operand_b(operand_b),
      .result(mul_r),
      .fflags(mul_ff)
  );

  logic [FLEN-1:0] div_r;
  logic [4:0] div_ff;
  fpu_div u_div (
      .clk(clk),
      .rst_n(rst_n),
      .en(div_en),
      .valid_in(div_valid_in),
      .fp_rm(fp_rm),
      .fp_fmt(fp_fmt),
      .operand_a(operand_a),
      .operand_b(operand_b),
      .ready_out(div_ready),
      .valid_out(div_valid_out),
      .result(div_r),
      .fflags(div_ff)
  );

  logic [FLEN-1:0] sqrt_r;
  logic [4:0] sqrt_ff;
  fpu_sqrt u_sqrt (
      .en(sqrt_en),
      .fp_rm(fp_rm),
      .fp_fmt(fp_fmt),
      .operand_a(operand_a),
      .result(sqrt_r),
      .fflags(sqrt_ff)
  );

  logic [FLEN-1:0] cmp_r;
  logic [4:0] cmp_ff;
  fpu_cmp u_cmp (
      .en(cmp_en),
      .cmp_op(cmp_op),
      .fp_fmt(fp_fmt),
      .operand_a(operand_a),
      .operand_b(operand_b),
      .result(cmp_r),
      .fflags(cmp_ff)
  );

  logic [FLEN-1:0] cvt_r;
  logic [4:0] cvt_ff;
  fpu_cvt u_cvt (
      .en(cvt_en),
      .cvt_to_int(fp_cvt_toint),
      .cvt_signed(fp_cvt_signed),
      .cvt_word(fp_cvt_word),
      .fp_rm(fp_rm),
      .fp_fmt(fp_fmt),
      .operand_a(operand_a),
      .result(cvt_r),
      .fflags(cvt_ff)
  );

  logic [FLEN-1:0] sign_r;
  fpu_sign u_sign (
      .en(sign_en),
      .operand_a(operand_a),
      .operand_b(operand_b),
      .sgn_op(fp_sgn_op),
      .fp_fmt(fp_fmt),
      .result(sign_r)
  );

  logic [FLEN-1:0] minmax_r;
  logic [4:0] minmax_ff;
  fpu_minmax u_minmax (
      .en(minmax_en),
      .operand_a(operand_a),
      .operand_b(operand_b),
      .min_sel(fp_min_sel),
      .fp_fmt(fp_fmt),
      .result(minmax_r),
      .fflags(minmax_ff)
  );

  logic [XLEN-1:0] mv_int_r;
  logic [FLEN-1:0] mv_fp_r;
  logic mv_to_int;
  fpu_mv u_mv (
      .en(mv_en),
      .int_src(int_operand),
      .fp_src(operand_a),
      .inst(inst),
      .fp_fmt(fp_fmt),
      .int_result(mv_int_r),
      .fp_result(mv_fp_r),
      .to_int(mv_to_int)
  );

  logic [FLEN-1:0] class_r;
  fpu_classify u_class (
      .en(class_en),
      .operand_a(operand_a),
      .fp_fmt(fp_fmt),
      .result(class_r)
  );

  logic [FLEN-1:0] cvtfmt_r;
  logic [4:0] cvtfmt_ff;
  fpu_cvt_fmt u_cvtfmt (
      .en(cvtfmt_en),
      .operand_a(operand_a),
      .fp_rm(fp_rm),
      .inst(inst),
      .result(cvtfmt_r),
      .fflags(cvtfmt_ff)
  );

  // to_int: FPU result must go to integer regfile
  assign to_int = cmp_en || (cvt_en && fp_cvt_toint) || class_en || mv_to_int;

  // Result mux
  always_comb begin
    result = operand_a;  // PASS default
    fflags = 5'b0;
    unique case (res_sel)
      FPU_SEL_ADDSUB: begin
        result = addsub_r;
        fflags = addsub_ff;
      end
      FPU_SEL_MUL: begin
        result = mul_r;
        fflags = mul_ff;
      end
      FPU_SEL_DIV: begin
        result = div_r;
        fflags = div_ff;
      end
      FPU_SEL_SQRT: begin
        result = sqrt_r;
        fflags = sqrt_ff;
      end
      FPU_SEL_CMP: begin
        result = cmp_r;
        fflags = cmp_ff;
      end
      FPU_SEL_CVT: begin
        result = cvt_r;
        fflags = cvt_ff;
      end
      FPU_SEL_SIGN: begin
        result = sign_r;
      end
      FPU_SEL_MINMAX: begin
        result = minmax_r;
        fflags = minmax_ff;
      end
      FPU_SEL_MV: begin
        result = mv_to_int ? mv_int_r : mv_fp_r;
      end
      FPU_SEL_CLASS: begin
        result = class_r;
      end
      FPU_SEL_CVTFMT: begin
        result = cvtfmt_r;
        fflags = cvtfmt_ff;
      end
      default: begin
        result = operand_a;
      end
    endcase
  end

endmodule

`endif  // FPU_TOP_SV
