`ifndef PKG_FPU_TYPES_H
`define PKG_FPU_TYPES_H

`timescale 1ns / 1ps

`include "isa_pkg.sv"

package pkg_fpu_types;

  import isa_pkg::*;


  typedef struct packed {
    logic [FLEN-1:0] result;
    logic [4:0]      fflags;
  } fp_result_t;

  localparam logic [31:0] FP32_QNAN = 32'h7FC0_0000;
  localparam logic [63:0] FP64_QNAN = 64'h7FF8_0000_0000_0000;

  function automatic logic [63:0] fp_box_single(input logic [31:0] value);
    return {32'hFFFF_FFFF, value};
  endfunction

  function automatic logic fp_single_is_boxed(input logic [63:0] value);
    return value[63:32] == 32'hFFFF_FFFF;
  endfunction

  function automatic logic [31:0] fp_unbox_single(input logic [63:0] value);
    if (fp_single_is_boxed(value)) begin
      return value[31:0];
    end
    return FP32_QNAN;
  endfunction

  function automatic logic [63:0] fp_canonical_nan(input fp_fmt_t fmt);
    return (fmt == FP_FMT_S) ? fp_box_single(FP32_QNAN) : FP64_QNAN;
  endfunction

  function automatic logic [63:0] fp_zero(input fp_fmt_t fmt, input logic sign);
    if (fmt == FP_FMT_S) begin
      return fp_box_single({sign, 31'd0});
    end
    return {sign, 63'd0};
  endfunction

  function automatic logic [63:0] fp_inf(input fp_fmt_t fmt, input logic sign);
    if (fmt == FP_FMT_S) begin
      return fp_box_single({sign, 8'hFF, 23'd0});
    end
    return {sign, 11'h7FF, 52'd0};
  endfunction

  function automatic logic [63:0] fp_move_to_int_bits(input logic [63:0] value, input fp_fmt_t fmt);
    logic [31:0] single_value;
    if (fmt == FP_FMT_S) begin
      single_value = fp_unbox_single(value);
      return {{32{single_value[31]}}, single_value};
    end
    return value;
  endfunction

  function automatic logic [63:0] fp_move_to_fp_bits(input logic [63:0] value, input fp_fmt_t fmt);
    if (fmt == FP_FMT_S) begin
      return fp_box_single(value[31:0]);
    end
    return value;
  endfunction

  function automatic logic [63:0] fp_single_to_double_bits(input logic [31:0] value);
    logic sign;
    logic [7:0] exp_s;
    logic [22:0] frac_s;
    logic [22:0] norm_frac;
    logic [10:0] exp_d;
    logic [51:0] frac_d;
    int shift_count;

    sign   = value[31];
    exp_s  = value[30:23];
    frac_s = value[22:0];
    exp_d  = 11'd0;
    frac_d = 52'd0;

    if ((exp_s == 8'hFF) && (frac_s != 23'd0)) begin
      frac_d = {1'b1, frac_s[21:0], 29'd0};
      return {sign, 11'h7FF, frac_d};
    end

    if (exp_s == 8'hFF) begin
      return {sign, 11'h7FF, 52'd0};
    end

    if ((exp_s == 8'd0) && (frac_s == 23'd0)) begin
      return {sign, 11'd0, 52'd0};
    end

    if (exp_s == 8'd0) begin
      norm_frac = frac_s;
      shift_count = 0;
      while ((norm_frac[22] == 1'b0) && (norm_frac != 23'd0)) begin
        norm_frac = norm_frac << 1;
        shift_count++;
      end
      exp_d = 11'(897 - shift_count);
      frac_d = {norm_frac[21:0], 29'd0};
      return {sign, exp_d, frac_d};
    end

    exp_d  = 11'(exp_s) + 11'd896;
    frac_d = {frac_s, 29'd0};
    return {sign, exp_d, frac_d};
  endfunction

  function automatic fp_result_t fp_double_to_single_boxed(
      input logic [63:0] value,
      input logic [2:0]  fp_rm
  );
    fp_result_t res;
    logic sign;
    logic [10:0] exp_d;
    logic [51:0] frac_d;
    logic is_nan, is_snan, is_inf, is_zero;
    logic [52:0] mant53;
    logic [55:0] mant56;
    logic [26:0] sig27;
    logic guard_bit, round_bit, sticky_bit, lsb_bit;
    logic round_up;
    logic [24:0] sig24_rounded;
    logic [23:0] rounded_sig24;
    logic [7:0] packed_exp;
    logic [22:0] packed_frac;
    logic of_flag, uf_flag, nx_flag;
    logic sticky_extra;
    int exp_unbiased;
    int exp_working;
    int shift_count;
    int sub_shift;

    res.result = fp_box_single(32'd0);
    res.fflags = 5'd0;

    sign    = value[63];
    exp_d   = value[62:52];
    frac_d  = value[51:0];
    is_nan  = (exp_d == 11'h7FF) && (frac_d != 52'd0);
    is_snan = is_nan && !frac_d[51];
    is_inf  = (exp_d == 11'h7FF) && (frac_d == 52'd0);
    is_zero = (exp_d == 11'd0) && (frac_d == 52'd0);

    if (is_snan) begin
      res.result = fp_box_single(FP32_QNAN);
      res.fflags[4] = 1'b1;
      return res;
    end

    if (is_nan) begin
      res.result = fp_box_single(FP32_QNAN);
      return res;
    end

    if (is_inf) begin
      res.result = fp_inf(FP_FMT_S, sign);
      return res;
    end

    if (is_zero) begin
      res.result = fp_zero(FP_FMT_S, sign);
      return res;
    end

    mant53 = (exp_d != 11'd0) ? {1'b1, frac_d} : {1'b0, frac_d};
    if (exp_d == 11'd0) begin
      exp_unbiased = -1022;
      while ((mant53[52] == 1'b0) && (mant53 != 53'd0)) begin
        mant53 = mant53 << 1;
        exp_unbiased--;
      end
    end else begin
      exp_unbiased = exp_d - 1023;
    end

    mant56 = {mant53, 3'b000};
    sig27  = mant56[55:29];
    sig27[0] = sig27[0] | (|mant56[28:0]);
    exp_working = exp_unbiased;

    if (exp_working < -126) begin
      sub_shift = -126 - exp_working;
      if (sub_shift >= 27) begin
        sticky_extra = |sig27;
        sig27 = 27'd0;
        sig27[0] = sticky_extra;
      end else if (sub_shift > 0) begin
        sticky_extra = |(sig27 & ((27'd1 << sub_shift) - 27'd1));
        sig27 = sig27 >> sub_shift;
        sig27[0] = sig27[0] | sticky_extra;
      end
      exp_working = -126;
    end

    guard_bit  = sig27[2];
    round_bit  = sig27[1];
    sticky_bit = sig27[0];
    lsb_bit    = sig27[3];
    nx_flag    = guard_bit | round_bit | sticky_bit;

    unique case (fp_rm)
      3'b000:  round_up = guard_bit & (round_bit | sticky_bit | lsb_bit);
      3'b001:  round_up = 1'b0;
      3'b010:  round_up = sign & (guard_bit | round_bit | sticky_bit);
      3'b011:  round_up = !sign & (guard_bit | round_bit | sticky_bit);
      3'b100:  round_up = guard_bit;
      default: round_up = guard_bit & (round_bit | sticky_bit | lsb_bit);
    endcase

    sig24_rounded = {1'b0, sig27[26:3]} + {24'd0, round_up};
    if (sig24_rounded[24]) begin
      rounded_sig24 = sig24_rounded[24:1];
      exp_working = exp_working + 1;
    end else begin
      rounded_sig24 = sig24_rounded[23:0];
    end

    of_flag = (exp_working > 127);
    uf_flag = 1'b0;

    if (of_flag) begin
      unique case (fp_rm)
        3'b001:  res.result = fp_box_single(sign ? 32'hFF7F_FFFF : 32'h7F7F_FFFF);
        3'b010:  res.result = sign ? fp_inf(FP_FMT_S, 1'b1) : fp_box_single(32'h7F7F_FFFF);
        3'b011:  res.result = sign ? fp_box_single(32'hFF7F_FFFF) : fp_inf(FP_FMT_S, 1'b0);
        default: res.result = fp_inf(FP_FMT_S, sign);
      endcase
      res.fflags[2] = 1'b1;
      res.fflags[0] = 1'b1;
      return res;
    end

    if (rounded_sig24 == 24'd0) begin
      packed_exp  = 8'd0;
      packed_frac = 23'd0;
    end else if (!rounded_sig24[23]) begin
      packed_exp  = 8'd0;
      packed_frac = rounded_sig24[22:0];
    end else begin
      packed_exp  = 8'(exp_working + 127);
      packed_frac = rounded_sig24[22:0];
    end

    uf_flag = (packed_exp == 8'd0) && (packed_frac != 23'd0) && nx_flag;
    res.result = fp_box_single({sign, packed_exp, packed_frac});
    res.fflags[1] = uf_flag;
    res.fflags[0] = nx_flag;
    return res;
  endfunction

  function automatic logic [63:0] fp_prepare_arith_operand(
      input logic [63:0] value,
      input fp_fmt_t     fmt
  );
    if (fmt == FP_FMT_S) begin
      return fp_single_to_double_bits(fp_unbox_single(value));
    end
    return value;
  endfunction

  function automatic fp_result_t fp_finish_arith_result(
      input logic [63:0] value,
      input logic [4:0]  fflags_in,
      input logic [2:0]  fp_rm,
      input fp_fmt_t     fmt
  );
    fp_result_t res;
    fp_result_t narrowed;

    if (fmt == FP_FMT_S) begin
      narrowed   = fp_double_to_single_boxed(value, fp_rm);
      res.result = narrowed.result;
      res.fflags = fflags_in | narrowed.fflags;
      return res;
    end

    res.result = value;
    res.fflags = fflags_in;
    return res;
  endfunction

  function automatic logic [63:0] fp_classify_bits(
      input logic [63:0] value,
      input fp_fmt_t     fmt
  );
    logic sign;
    logic [10:0] exp_d;
    logic [51:0] frac_d;
    logic [7:0] exp_s;
    logic [22:0] frac_s;
    logic is_nan;
    logic is_snan;
    logic is_inf;
    logic is_zero;
    logic is_subnormal;
    logic [63:0] result_bits;
    logic [31:0] single_value;

    result_bits = 64'd0;

    if (fmt == FP_FMT_S) begin
      single_value = fp_unbox_single(value);
      sign         = single_value[31];
      exp_s        = single_value[30:23];
      frac_s       = single_value[22:0];
      is_nan       = (exp_s == 8'hFF) && (frac_s != 23'd0);
      is_snan      = is_nan && !frac_s[22];
      is_inf       = (exp_s == 8'hFF) && (frac_s == 23'd0);
      is_zero      = (exp_s == 8'd0) && (frac_s == 23'd0);
      is_subnormal = (exp_s == 8'd0) && (frac_s != 23'd0);
    end else begin
      sign         = value[63];
      exp_d        = value[62:52];
      frac_d       = value[51:0];
      is_nan       = (exp_d == 11'h7FF) && (frac_d != 52'd0);
      is_snan      = is_nan && !frac_d[51];
      is_inf       = (exp_d == 11'h7FF) && (frac_d == 52'd0);
      is_zero      = (exp_d == 11'd0) && (frac_d == 52'd0);
      is_subnormal = (exp_d == 11'd0) && (frac_d != 52'd0);
    end

    if (is_nan) begin
      result_bits[is_snan ? 8 : 9] = 1'b1;
    end else if (is_inf) begin
      result_bits[sign ? 0 : 7] = 1'b1;
    end else if (is_zero) begin
      result_bits[sign ? 3 : 4] = 1'b1;
    end else if (is_subnormal) begin
      result_bits[sign ? 2 : 5] = 1'b1;
    end else begin
      result_bits[sign ? 1 : 6] = 1'b1;
    end

    return result_bits;
  endfunction

  function automatic logic [63:0] fp_sign_inject_bits(
      input logic [63:0] value_a,
      input logic [63:0] value_b,
      input fp_fmt_t     fmt,
      input logic [1:0]  sign_op
  );
    logic sign_a;
    logic sign_b;
    logic new_sign;
    logic [31:0] a_s;
    logic [31:0] b_s;

    if (fmt == FP_FMT_S) begin
      a_s = fp_unbox_single(value_a);
      b_s = fp_unbox_single(value_b);
      sign_a = a_s[31];
      sign_b = b_s[31];
    end else begin
      sign_a = value_a[63];
      sign_b = value_b[63];
    end

    unique case (sign_op)
      2'd0: new_sign = sign_b;
      2'd1: new_sign = !sign_b;
      default: new_sign = sign_a ^ sign_b;
    endcase

    if (fmt == FP_FMT_S) begin
      return fp_box_single({new_sign, a_s[30:0]});
    end
    return {new_sign, value_a[62:0]};
  endfunction

endpackage

`endif
