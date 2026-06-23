`timescale 1ns / 1ps

`ifndef FPU_CVT_FMT_SV
`define FPU_CVT_FMT_SV

`include "isa_pkg.sv"
import isa_pkg::*;

// fpu_cvt_fmt.sv — FCVT.S.D / FCVT.D.S  (float-to-float precision conversion)
//
// FCVT.S.D: double → single  (narrows, may lose precision, may overflow)
// FCVT.D.S: single → double  (exact widening; NaN-unbox input first)
//
// @Note NaN boxing: the single operand inside a 64-bit fp register is in
//   bits [31:0]; upper bits must all be 1 per spec. We do NOT validate the
//   box here (hardware performance path), but a debug assertion could be added.
module fpu_cvt_fmt (
    input  logic            en,
    input  logic [FLEN-1:0] operand_a,
    input  logic [2:0]      fp_rm,
    input  instruction_t    inst,        // FCVT_SD or FCVT_DS
    output logic [FLEN-1:0] result,
    output logic [4:0]      fflags
);

  localparam logic [63:0] D_QNAN = 64'h7FF8_0000_0000_0000;
  localparam logic [31:0] S_QNAN = 32'h7FC0_0000;

  // -------------------------------------------------------------------------
  // FCVT.D.S: single → double (exact widening)
  // Unbox [31:0], expand mantissa and exponent.
  // -------------------------------------------------------------------------
  logic [31:0]  s_in;
  logic         s_sign;
  logic [7:0]   s_exp;
  logic [22:0]  s_frac;
  logic         s_is_nan, s_is_qnan, s_is_snan, s_is_inf, s_is_zero, s_is_subnorm;
  logic [63:0]  d_from_s;

  assign s_in       = operand_a[31:0];
  assign s_sign     = s_in[31];
  assign s_exp      = s_in[30:23];
  assign s_frac     = s_in[22:0];
  assign s_is_nan   = (s_exp == 8'hFF) && (s_frac != 23'd0);
  assign s_is_qnan  = s_is_nan &&  s_in[22];
  assign s_is_snan  = s_is_nan && !s_in[22];
  assign s_is_inf   = (s_exp == 8'hFF) && (s_frac == 23'd0);
  assign s_is_zero  = (s_exp == 8'd0)  && (s_frac == 23'd0);
  assign s_is_subnorm = (s_exp == 8'd0) && (s_frac != 23'd0);

  logic [63:0] d_result_ds;
  logic [4:0]  d_fflags_ds;

  always_comb begin
    d_result_ds = '0;
    d_fflags_ds = 5'b0;

    if (s_is_snan) begin
      d_result_ds = D_QNAN; d_fflags_ds[4] = 1'b1;
    end else if (s_is_qnan || s_is_nan) begin
      d_result_ds = D_QNAN;
    end else if (s_is_inf) begin
      d_result_ds = {s_sign, 11'h7FF, 52'd0};
    end else if (s_is_zero) begin
      d_result_ds = {s_sign, 63'd0};
    end else if (s_is_subnorm) begin
      // Subnormal single → normalise, then convert to double
      // Find leading 1 in s_frac[22:0]
      logic [4:0] lz;
      logic [22:0] norm_frac;
      lz = 5'd0;
      for (int i = 22; i >= 0; i--)
        if (!s_frac[i] && lz == 5'd0) lz = lz + 1'b1;
      // actual normalised: exp_unbiased = 1 - 127 - lz = -126 - lz
      // double biased exp = -126 - lz + 1023
      norm_frac   = s_frac << (lz + 1);
      d_result_ds = {s_sign, 11'(-126 - int'(lz) + 1023), norm_frac, 29'd0};
    end else begin
      // Normal single: rebias exponent (127 → 1023), zero-extend mantissa
      logic [10:0] d_exp;
      d_exp       = 11'(int'(s_exp) - 127 + 1023);
      d_result_ds = {s_sign, d_exp, s_frac, 29'd0};
    end
  end

  // -------------------------------------------------------------------------
  // FCVT.S.D: double → single (narrowing, rounding)
  // Unpack double, round to single precision.
  // -------------------------------------------------------------------------
  logic         d_sign;
  logic [10:0]  d_exp;
  logic [51:0]  d_frac;
  logic         d_is_nan, d_is_qnan, d_is_snan, d_is_inf, d_is_zero;

  assign d_sign   = operand_a[63];
  assign d_exp    = operand_a[62:52];
  assign d_frac   = operand_a[51:0];
  assign d_is_nan  = (d_exp == 11'h7FF) && (d_frac != 52'd0);
  assign d_is_qnan = d_is_nan &&  operand_a[51];
  assign d_is_snan = d_is_nan && !operand_a[51];
  assign d_is_inf  = (d_exp == 11'h7FF) && (d_frac == 52'd0);
  assign d_is_zero = (d_exp == 11'd0)   && (d_frac == 52'd0);

  logic [63:0] d_result_sd;
  logic [4:0]  d_fflags_sd;

  always_comb begin
    d_result_sd = {32'hFFFF_FFFF, 32'd0};  // default NaN-boxed
    d_fflags_sd = 5'b0;

    if (d_is_snan) begin
      d_result_sd = {32'hFFFF_FFFF, S_QNAN}; d_fflags_sd[4] = 1'b1;
    end else if (d_is_qnan || d_is_nan) begin
      d_result_sd = {32'hFFFF_FFFF, S_QNAN};
    end else if (d_is_inf) begin
      d_result_sd = {32'hFFFF_FFFF, d_sign, 8'hFF, 23'd0};
    end else if (d_is_zero) begin
      d_result_sd = {32'hFFFF_FFFF, d_sign, 31'd0};
    end else begin
      // Rebias and round significand from 52 to 23 bits
      logic signed [12:0] exp_unbiased;
      logic [7:0]  s_exp_out;
      logic [22:0] s_frac_out;
      logic        of_flag, uf_flag, nx;

      exp_unbiased = $signed({2'b0, d_exp}) - 13'sd1023;
      of_flag      = (exp_unbiased > 13'sd127);
      uf_flag      = (exp_unbiased < -13'sd126);
      nx           = 1'b0;

      if (of_flag) begin
        // @Note: correct result depends on rounding mode
        d_result_sd = {32'hFFFF_FFFF, d_sign, 8'hFF, 23'd0};
        d_fflags_sd[2] = 1'b1; d_fflags_sd[0] = 1'b1;
      end else if (uf_flag) begin
        // Flush to zero (subnormal output @Todo: full subnormal output)
        d_result_sd = {32'hFFFF_FFFF, d_sign, 31'd0};
        d_fflags_sd[1] = 1'b1; d_fflags_sd[0] = 1'b1;
      end else begin
        // Normal: take top 23 bits of 52-bit fraction + GRS rounding
        logic [28:0] grs_bits;
        logic        guard, rnd, sticky, lsb, round_up;
        logic [23:0] sig24;
        grs_bits = d_frac[28:0];
        guard    = d_frac[28];
        rnd      = d_frac[27];
        sticky   = |d_frac[26:0];
        lsb      = d_frac[29];
        nx       = guard | rnd | sticky;
        unique case (fp_rm)
          3'b000: round_up = guard & (rnd | sticky | lsb);
          3'b001: round_up = 1'b0;
          3'b010: round_up = d_sign & (guard | rnd | sticky);
          3'b011: round_up = !d_sign & (guard | rnd | sticky);
          3'b100: round_up = guard;
          default: round_up = guard & (rnd | sticky | lsb);
        endcase
        
        sig24 = {1'b0, d_frac[51:29]} + {23'd0, round_up};
        if (sig24[23]) begin
          s_exp_out  = 8'(exp_unbiased + 13'sd1 + 13'sd127);
          s_frac_out = sig24[22:0];
        end else begin
          s_exp_out  = 8'(exp_unbiased + 13'sd127);
          s_frac_out = sig24[22:0];
        end
        d_result_sd = {32'hFFFF_FFFF, d_sign, s_exp_out, s_frac_out};
        d_fflags_sd[0] = nx;
      end
    end
  end

  // Output mux
  always_comb begin
    result = '0;
    fflags = 5'b0;
    if (en) begin
      if (inst == INST_FCVT_DS) begin
        result = d_result_ds;
        fflags = d_fflags_ds;
      end else begin  // FCVT_SD
        result = d_result_sd;
        fflags = d_fflags_sd;
      end
    end
  end

endmodule

`endif // FPU_CVT_FMT_SV
