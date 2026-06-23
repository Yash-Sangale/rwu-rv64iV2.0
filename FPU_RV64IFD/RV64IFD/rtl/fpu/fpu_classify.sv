`timescale 1ns / 1ps

`ifndef FPU_CLASSIFY_SV
`define FPU_CLASSIFY_SV

`include "isa_pkg.sv"
import isa_pkg::*;

// fpu_classify.sv — FCLASS.S / FCLASS.D
//
// Result is a 64-bit integer with exactly one bit set (bits [9:0]):
//   [0]  −∞
//   [1]  negative normal
//   [2]  negative subnormal
//   [3]  −0
//   [4]  +0
//   [5]  positive subnormal
//   [6]  positive normal
//   [7]  +∞
//   [8]  signalling NaN
//   [9]  quiet NaN
//
// Result goes to integer register file (fp_to_int=1 in fpu_ctrl).
module fpu_classify (
    input  logic            en,
    input  logic [FLEN-1:0] operand_a,
    input  logic [1:0]      fp_fmt,
    output logic [FLEN-1:0] result
);

  // Double precision classify
  function automatic logic [9:0] d_class(input logic [63:0] v);
    logic        sign;
    logic [10:0] exp;
    logic [51:0] frac;
    logic        is_zero, is_subnorm, is_normal, is_inf, is_nan, is_qnan, is_snan;
    sign      = v[63];
    exp       = v[62:52];
    frac      = v[51:0];
    is_nan    = (exp == 11'h7FF) && (frac != 52'd0);
    is_qnan   = is_nan &&  v[51];
    is_snan   = is_nan && !v[51];
    is_inf    = (exp == 11'h7FF) && (frac == 52'd0);
    is_zero   = (exp == 11'd0)   && (frac == 52'd0);
    is_subnorm= (exp == 11'd0)   && (frac != 52'd0);
    is_normal = !is_nan && !is_inf && !is_zero && !is_subnorm;
    return {is_qnan, is_snan,
            is_inf && !sign, is_normal && !sign, is_subnorm && !sign, is_zero && !sign,
            is_zero && sign, is_subnorm && sign, is_normal && sign, is_inf && sign};
  endfunction

  // Single precision classify (operates on bits [31:0])
  function automatic logic [9:0] s_class(input logic [31:0] v);
    logic       sign;
    logic [7:0] exp;
    logic [22:0] frac;
    logic is_zero, is_subnorm, is_normal, is_inf, is_nan, is_qnan, is_snan;
    sign       = v[31];
    exp        = v[30:23];
    frac       = v[22:0];
    is_nan     = (exp == 8'hFF) && (frac != 23'd0);
    is_qnan    = is_nan &&  v[22];
    is_snan    = is_nan && !v[22];
    is_inf     = (exp == 8'hFF) && (frac == 23'd0);
    is_zero    = (exp == 8'd0)  && (frac == 23'd0);
    is_subnorm = (exp == 8'd0)  && (frac != 23'd0);
    is_normal  = !is_nan && !is_inf && !is_zero && !is_subnorm;
    return {is_qnan, is_snan,
            is_inf && !sign, is_normal && !sign, is_subnorm && !sign, is_zero && !sign,
            is_zero && sign, is_subnorm && sign, is_normal && sign, is_inf && sign};
  endfunction

  always_comb begin
    result = '0;
    if (en) begin
      if (fp_fmt == FP_FMT_D)
        result = {54'b0, d_class(operand_a)};
      else
        result = {54'b0, s_class(operand_a[31:0])};
    end
  end

endmodule

`endif // FPU_CLASSIFY_SV
