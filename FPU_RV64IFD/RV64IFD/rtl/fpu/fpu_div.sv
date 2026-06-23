// =============================================================================
// fpu_div.sv — IEEE 754 Double-Precision Divide 
//
// Algorithm:
//   result_sign = sign_a ^ sign_b
//   result_exp  = exp_a - exp_b + 1023  (exact bias correction, signed)
//   result_mant = (mant_a << 55) / mant_b  →  56-bit quotient
//
//  numerator construction:
//   mant_a is 53 bits with hidden at [52].
//   Shifting left by 55 gives a 108-bit numerator; dividing by the 53-bit
//   mant_b yields a 56-bit quotient with hidden at [55], frac at [54:3],
//   GRS at [2:0] — exactly matching the layout used in fpu_addsub/fpu_mul.
//
//   Quotient[55]=1  → already normalised (1.x / 1.x ≥ 0.5; hidden lands at [55])
//   Quotient[55]=0  → left-shift 1, decrement exponent (mant_a < mant_b case)
//
// The remainder from the integer division is non-zero ↔ result is inexact;
// its presence is OR'd into the sticky bit.
// @warning : Problems it still has: the 108/53-bit division synthesizes to a massive combinational tree. Acceptable in simulation; fails timing in synthesis for any real target.
// @note: Fully pipelined (registers between stages) - for High-frequency designs where  maximum throughput is wanted (a new divide can start every cycle, results come out N cycles later). Typical for FPUs in out-of-order CPUs. Make sure Latency is fixed and known at design time. will need input  logic clk, input  logic  rst_n, and output logic  result_valid.
// somehting like // Stage 1: unpack, special case detect, exp compute
//                // Stage 2–N: SRT or Newton-Raphson iterations (each registered)
//                // Stage N+1: round and pack
// @note: Multi-cycle with handshake 
// module fpu_div (
//     input  logic        clk,
//     input  logic        rst_n,
//     input  logic        valid_in,   // consumer asserts when operands are ready
//     output logic        ready_in,   // div asserts when it can accept new input
//     output logic        valid_out,  // div asserts when result is ready
//     input  logic        ready_out,  // consumer asserts when it can accept result
//     ...
// );
// Iterative SRT or Goldschmidt divider
// Holds ready_in=0 while computing
// Asserts valid_out when done
// @@= For area-constrained designs (FPGA, small ASIC) where   the gate count of a fully pipelined divider cannot be afford, but still need correct timing. This is the most common real-world choice for RISC-V FPUs — division is rare enough that stalling the pipeline for 10–20 cycles is acceptable. The RISC-V spec explicitly permits variable-latency division.
// @TODO: Newton-Raphson divider
// =============================================================================

`ifndef FPU_DIV_SV
`define FPU_DIV_SV 

`timescale 1ns / 1ps

`include "isa_pkg.sv"
import isa_pkg::*;


module fpu_div (
    input  logic            clk,
    input  logic            rst_n,
    input  logic            en,
    input  logic [     1:0] fp_fmt,     // FP_FMT_S or FP_FMT_D
    input  logic [     2:0] fp_rm,
    input  logic [FLEN-1:0] operand_a,
    input  logic [FLEN-1:0] operand_b,
    output logic [FLEN-1:0] result,
    output logic [     4:0] fflags,

    input  logic valid_in,   //  asserted when operands are ready
    output logic valid_out,  // div asserted when result is ready
    output logic ready_out   //  asserted when it can accept result
);

  // Suppress unused clk/rst — present for future multi-cycle upgrade
  logic _unused;
  assign _unused   = clk & rst_n;

  assign ready_out = 1'b1;
  assign valid_out = valid_in & en;



  function automatic logic [63:0] s_to_d(input logic [31:0] s);
    logic sign;
    logic [7:0] se;
    logic [22:0] sf;
    sign = s[31];
    se   = s[30:23];
    sf   = s[22:0];
    if (se == 8'hFF && sf != 23'd0) return 64'h7FF8_0000_0000_0000;
    if (se == 8'hFF) return {sign, 11'h7FF, 52'd0};
    if (se == 8'd0 && sf == 23'd0) return {sign, 63'd0};
    return {sign, 11'(int'(se) - 127 + 1023), sf, 29'd0};
  endfunction

  function automatic logic [63:0] d_to_s_nanbox(input logic [63:0] d, input logic [2:0] rm);
    logic ds;
    logic [10:0] de;
    logic [51:0] df;
    logic [7:0] se;
    logic [22:0] sf;
    logic signed [12:0] ue;
    logic guard, rnd, stky, lsb, rup;
    logic [23:0] sig24;
    ds = d[63];
    de = d[62:52];
    df = d[51:0];
    if (de == 11'h7FF && df != 52'd0) return {32'hFFFF_FFFF, 1'b0, 8'hFF, 23'h400000};
    if (de == 11'h7FF) return {32'hFFFF_FFFF, ds, 8'hFF, 23'd0};
    if (de == 11'd0) return {32'hFFFF_FFFF, ds, 31'd0};
    ue = $signed({2'b0, de}) - 13'sd1023;
    guard = df[28];
    rnd = df[27];
    stky = |df[26:0];
    lsb = df[29];
    unique case (rm)
      3'b000:  rup = guard & (rnd | stky | lsb);
      3'b001:  rup = 1'b0;
      3'b010:  rup = ds & (guard | rnd | stky);
      3'b011:  rup = !ds & (guard | rnd | stky);
      3'b100:  rup = guard;
      default: rup = guard & (rnd | stky | lsb);
    endcase
    sig24 = {1'b0, df[51:29]} + {23'd0, rup};
    if (ue > 13'sd127) return {32'hFFFF_FFFF, ds, 8'hFF, 23'd0};
    if (ue < -13'sd126) return {32'hFFFF_FFFF, ds, 31'd0};
    if (sig24[23]) begin
      se = 8'(ue + 13'sd1 + 13'sd127);
      sf = sig24[22:0];
    end else begin
      se = 8'(ue + 13'sd127);
      sf = sig24[22:0];
    end
    return {32'hFFFF_FFFF, ds, se, sf};
  endfunction

  logic [63:0] opa, opb;
  always_comb begin
    if (fp_fmt == 2'b00) begin
      opa = s_to_d(operand_a[31:0]);
      opb = s_to_d(operand_b[31:0]);
    end else begin
      opa = operand_a;
      opb = operand_b;
    end
  end

  // Unpack
  logic sign_a, sign_b;
  logic [10:0] exp_a, exp_b;
  logic [52:0] mant_a, mant_b;

  assign sign_a = opa[63];
  assign sign_b = opb[63];
  assign exp_a  = opa[62:52];
  assign exp_b  = opb[62:52];
  assign mant_a = {(exp_a != 11'd0), opa[51:0]};
  assign mant_b = {(exp_b != 11'd0), opb[51:0]};

  // Special values
  logic is_nan_a, is_nan_b;
  logic is_snan_a, is_snan_b;
  logic is_inf_a, is_inf_b;
  logic is_zero_a, is_zero_b;

  assign is_nan_a  = (exp_a == 11'h7FF) && (opa[51:0] != 52'd0);
  assign is_nan_b  = (exp_b == 11'h7FF) && (opb[51:0] != 52'd0);
  assign is_snan_a = is_nan_a && !opa[51];
  assign is_snan_b = is_nan_b && !opb[51];
  assign is_inf_a  = (exp_a == 11'h7FF) && (operand_a[51:0] == 52'd0);
  assign is_inf_b  = (exp_b == 11'h7FF) && (operand_b[51:0] == 52'd0);
  assign is_zero_a = (exp_a == 11'd0) && (operand_a[51:0] == 52'd0);
  assign is_zero_b = (exp_b == 11'd0) && (operand_b[51:0] == 52'd0);

  localparam logic [63:0] QNAN = 64'h7FF8_0000_0000_0000;
  localparam logic [63:0] INF_POS = 64'h7FF0_0000_0000_0000;
  localparam logic [63:0] INF_NEG = 64'hFFF0_0000_0000_0000;
  localparam logic [63:0] MAX_FIN_POS = 64'h7FEF_FFFF_FFFF_FFFF;
  localparam logic [63:0] MAX_FIN_NEG = 64'hFFEF_FFFF_FFFF_FFFF;


  logic result_sign;
  assign result_sign = sign_a ^ sign_b;

  // -------------------------------------------------------------------------
  // Exponent difference (signed, 13 bits to prevent wrap)
  //
  // result_exp_unbiased = (exp_a - 1023) - (exp_b - 1023)
  //                     = exp_a - exp_b
  // result_exp_biased   = exp_a - exp_b + 1023
  // -------------------------------------------------------------------------

  logic signed [12:0] exp_result;
  assign exp_result = $signed({2'b0, exp_a}) - $signed({2'b0, exp_b});

  // -------------------------------------------------------------------------
  // Mantissa division
  //
  //  numerator = mant_a << 55  (108 bits total: 53+55)
  //  quotient  = numerator / mant_b  (56-bit result)
  //
  //   Why << 55?
  //   mant_a and mant_b are both 1.fraction values scaled to integers as
  //   53-bit numbers (hidden at [52]).  Dividing gives a value in [0.5, 2.0).
  //   We want a 56-bit result with hidden at [55] and GRS at [2:0]:
  //     - hidden needs 1 bit above [54:3 frac region]
  //     - 3 bits below for GRS
  //     - Total significand bits below numerator MSB: 52 frac + 3 GRS = 55
  //   → shift left by 55.
  //
  //   quotient[55]=1 for mant_a >= mant_b (ratio ≥ 1.0), hidden at [55] ✓
  //   quotient[55]=0 for mant_a <  mant_b (ratio < 1.0), shift left 1, exp-1
  // -------------------------------------------------------------------------

  logic [107:0] num;
  logic [107:0] quotient;
  logic [107:0] remainder;
  logic         rem_nonzero;


  always_comb begin
    num         = {55'd0, mant_a} << 55;  // 108-bit numerator
    /*
      When you divide two numbers A and B that both have their highest bit at position 52, the resulting quotient A/B falls into the range [0.5,2.0).

      To get a 56-bit result (where the hidden bit lands safely at bit [55] and the Guard, Round, Sticky bits land at [2:0]), you must multiply the numerator by 255.
      By changing the shift to << 52, your quotient's MSB landed at bit [52] instead of [55].

      Because of this, your normalization logic (if (quotient[55])) always saw a 0, forcing an erroneous left-shift. Then, when your rounding logic extracted norm_q[55:3], it sliced the wrong part of the mantissa, chopping off the hidden bit entirely and bringing fractional bits into the wrong position (which is where the unexpected 4 in your 7fe4 mantissa came from).
     */
    // num         = {55'd0, mant_a} << 52;  // 108-bit numerator
    quotient    = num / {55'd0, mant_b};  // 56-bit quotient
    remainder   = num - (quotient * {55'd0, mant_b});
    rem_nonzero = |remainder;
  end

  // Normalize quotient
  //   quotient[55]=1 : hidden already at [55]; already normalised.
  //   quotient[55]=0 : hidden dropped to [54]; left-shift 1, exp-1.

  logic [55:0] norm_q;
  logic signed [12:0] norm_exp;

  always_comb begin
    if (quotient[55]) begin
      norm_q   = quotient;
      norm_exp = exp_result;
    end else begin
      norm_q   = quotient << 1;
      norm_exp = exp_result - 1;
    end
  end

  // -------------------------------------------------------------------------
  // Round (GRS at norm_q[2:0]; significand at norm_q[55:3])
  //
  //  sig53_rounded is 54 bits so that rounding carry lands at [53],
  //      not [52] (which is the hidden bit).
  //      sticky includes rem_nonzero (any remainder → inexact).
  // -------------------------------------------------------------------------

  logic guard, rnd, stky, lsb;
  logic        round_up;
  logic [53:0] sig53_rounded;
  logic        nx_flag;

  always_comb begin
    guard   = norm_q[2];
    rnd     = norm_q[1];
    stky    = norm_q[0] | rem_nonzero;
    lsb     = norm_q[3];
    nx_flag = guard | rnd | stky;

    unique case (fp_rm)
      3'b000:  round_up = guard & (rnd | stky | lsb);
      3'b001:  round_up = 1'b0;
      3'b010:  round_up = result_sign & (guard | rnd | stky);
      3'b011:  round_up = !result_sign & (guard | rnd | stky);
      3'b100:  round_up = guard;
      default: round_up = guard & (rnd | stky | lsb);
    endcase

    sig53_rounded = {1'b0, norm_q[55:3]} + {53'd0, round_up};
  end

  // Post-round carry (same pattern as fpu_mul)
  logic signed [12:0] final_exp;
  logic        [51:0] final_frac;

  always_comb begin
    if (sig53_rounded[53]) begin
      final_exp  = norm_exp + 13'sd1;
      final_frac = sig53_rounded[52:1];
    end else begin
      final_exp  = norm_exp;
      final_frac = sig53_rounded[51:0];
    end
  end

  logic of_flag;
  assign of_flag = (final_exp > 13'sd1023);

  // D-precision output (internal wire)
  logic [63:0] d_result;
  logic [ 4:0] d_fflags;

  always_comb begin
    d_result = 64'd0;
    d_fflags = 5'b0;

    if (!en) begin
      d_result = 64'd0;

    end else if (is_snan_a || is_snan_b) begin
      d_result    = QNAN;
      d_fflags[4] = 1'b1;

    end else if (is_nan_a || is_nan_b) begin
      d_result = QNAN;

    end else if (is_zero_a && is_zero_b) begin
      d_result    = QNAN;  // 0/0 → NaN, invalid
      d_fflags[4] = 1'b1;

    end else if (is_inf_a && is_inf_b) begin
      d_result    = QNAN;  // ∞/∞ → NaN, invalid
      d_fflags[4] = 1'b1;

    end else if (is_zero_b) begin
      d_result    = result_sign ? INF_NEG : INF_POS;  // x/0 → ±∞, DZ
      d_fflags[3] = 1'b1;

    end else if (is_zero_a || is_inf_b) begin
      d_result = {result_sign, 63'd0};  // 0/x or x/∞ → ±0

    end else if (is_inf_a) begin
      d_result = result_sign ? INF_NEG : INF_POS;

    end else if (of_flag) begin
      unique case (fp_rm)
        3'b000:  d_result = result_sign ? INF_NEG : INF_POS;
        3'b001:  d_result = result_sign ? MAX_FIN_NEG : MAX_FIN_POS;
        3'b010:  d_result = result_sign ? INF_NEG : MAX_FIN_POS;
        3'b011:  d_result = result_sign ? MAX_FIN_NEG : INF_POS;
        3'b100:  d_result = result_sign ? INF_NEG : INF_POS;
        default: d_result = result_sign ? INF_NEG : INF_POS;
      endcase
      d_fflags[2] = 1'b1;
      d_fflags[0] = 1'b1;

    end else if (final_exp <= -13'sd1022) begin
      d_result    = {result_sign, 63'd0};
      d_fflags[1] = 1'b1;
      d_fflags[0] = 1'b1;

    end else begin
      d_result    = {result_sign, 11'(final_exp + 13'sd1023), final_frac};
      d_fflags[0] = nx_flag;
    end
  end

  // S/D final output mux — d_result holds D-precision value
  always_comb begin
    result = (en && fp_fmt == 2'b00) ? d_to_s_nanbox(d_result, fp_rm) : d_result;
    fflags = d_fflags;
  end

endmodule


`endif  // FPU_DIV_SV
