// =============================================================================
// fpu_sqrt.sv — IEEE 754 Double-Precision Square Root
//
// Algorithm: bit-by-bit non-restoring integer sqrt, no multiplication.
// Uses the identity:   (Q + 2^i)^2 = Q^2 + (2Q + 2^i) * 2^i
// So the cost of setting bit i, given running estimate Q and remainder R:
//   cost = (2*Q + 2^i) * 2^i  =  ({Q, 1'b1} << i)  in hardware
// If cost <= R: set bit i, R -= cost.
// This requires only shifts and adds — no squaring, no overflow.
//
// Wire widths:
//   mant_fixed [105:0]  — fixed-point significand (53 bits × 2^53 scale)
//   Q          [52:0]   — running sqrt estimate, 53 bits, hidden at [52]
//   R          [106:0]  — running remainder (one bit wider than mant_fixed)
//   cost       [106:0]  — ({Q, 1'b1} << i), at most 107 bits
//
// Exponent formula (KEY FIX):
//   val = mant * 2^(exp_a - 1023)
//   Let U = exp_a - 1023  (unbiased)
//   if U even: sqrt(val) = sqrt(mant) * 2^(U/2)
//              mant_input = mant_a  (53 bits)
//              result_exp_biased = U/2 + 1023
//   if U odd:  write val = (2*mant) * 2^((U-1))  (now even exponent)
//              sqrt(val) = sqrt(2*mant) * 2^((U-1)/2)
//              mant_input = mant_a << 1  (54 bits)
//              result_exp_biased = (U-1)/2 + 1023
//
//   Original buggy odd formula: ((exp_a - 1022) >> 1) + 1023
//     For exp_a=1024 (U=1, odd): gives (1024-1022)>>1+1023 = 1024  ← WRONG
//   Correct odd formula: ((U-1) >> 1) + 1023 = ((exp_a-1024) >> 1) + 1023
//     For exp_a=1024: (0>>1)+1023 = 1023  ← sqrt(2.0) ≈ 1.414, exp=0 ✓
//
// Rounding:
//   After computing Q (53-bit integer sqrt of mant_fixed), the remainder R
//   tells us whether the result is exact and which way to round.
//   For RNE: increment Q if R > Q (i.e., the true sqrt is closer to Q+1).
//   A conservative correct approach: if R != 0 (inexact), set NX; use
//   standard GRS rounding against the remainder.
//   We implement full RNE: round_up iff R*2 > Q (equivalently R > Q/2,
//   but using exact integer comparison: 2*R > Q after the final bit).
//   The extra half-bit check: round_up = (R << 1) > Q
// =============================================================================


`ifndef FPU_MUL_SV
`define FPU_MUL_SV 

`timescale 1ns / 1ps

`include "isa_pkg.sv"
import isa_pkg::*;

module fpu_mul (
    input  logic            en,
    input  logic [     1:0] fp_fmt,     // FP_FMT_S or FP_FMT_D
    input  logic [     2:0] fp_rm,
    input  logic [FLEN-1:0] operand_a,
    input  logic [FLEN-1:0] operand_b,
    output logic [FLEN-1:0] result,
    output logic [     4:0] fflags      // {NV[4], DZ[3], OF[2], UF[1], NX[0]}
);


  // S<->D helpers: upcast S input to D for computation; downcast result to S.
  // Matches the approach in fpu_addsub.sv — compute in double, pack result as single.
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

  // S/D operand mux: upcast single to double for unified compute path
  logic [63:0] opa, opb;
  always_comb begin
    if (fp_fmt == 2'b00) begin  // FP_FMT_S
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


  // Product sign
  logic result_sign;
  assign result_sign = sign_a ^ sign_b;

  // Mantissa product: 53 × 53 = 106 bits, MSB at [105]
  logic [105:0] product;
  assign product = {53'd0, mant_a} * {53'd0, mant_b};

  // Biased exponent sum (12 bits to catch overflow)
  // Both inputs have biased exponents; sum overcounts bias by 1023.
  logic [12:0] exp_sum;
  assign exp_sum = $signed({2'b0, exp_a}) + $signed({2'b0, exp_b}) - 13'sd1023;

  // -------------------------------------------------------------------------
  // Normalize product
  //
  // 1.x * 1.x = 1x.xxx (product MSB at [105]) or 1.xxx (MSB at [104])
  //
  // We extract 56 bits with hidden at [55], frac at [54:3], GRS at [2:0].
  //   product[105]=1 → right-shift 1 into {product[105:50]}, exp+1
  //   product[105]=0 → take {product[104:49]}, exp unchanged
  //
  // Both cases: norm_mant[55] = hidden bit = 1 for normal inputs.
  // -------------------------------------------------------------------------

  logic [55:0] norm_mant;  // 53 bits + 3 guard
  logic signed [12:0] norm_exp;

  always_comb begin
    if (product[105]) begin
      // Carry: take bits [105:50] → 56 bits, hidden at [55]
      norm_mant    = product[105:50];
      norm_mant[0] = norm_mant[0] | (|product[49:0]);  // sticky from lost bits
      norm_exp     = exp_sum + 13'sd1;
    end else begin
      // No carry: take bits [104:49] → 56 bits, hidden at [55]
      norm_mant    = product[104:49];
      norm_mant[0] = norm_mant[0] | (|product[48:0]);  // sticky
      norm_exp     = exp_sum;
    end
  end

  // -------------------------------------------------------------------------
  // Round
  //
  // GRS at norm_mant[2:0]; significand bits at norm_mant[55:3].
  // norm_mant[55:3] is 53 bits with hidden at [52] of the extracted field.
  //
  //  sig53_rounded is 54 bits to capture any rounding carry-out.
  //      Carry is at sig53_rounded[53], NOT [52].
  // -------------------------------------------------------------------------
  logic guard, rnd, stky, lsb;
  logic        round_up;
  logic [53:0] sig53_rounded;  // 54 bits: [53]=carry, [52]=hidden, [51:0]=frac
  logic        nx_flag;

  always_comb begin

    guard   = norm_mant[2];
    rnd     = norm_mant[1];
    stky    = norm_mant[0];
    lsb     = norm_mant[3];  // LSB of kept significand (RNE tie-breaking)
    nx_flag = guard | rnd | stky;

    unique case (fp_rm)
      3'b000:  round_up = guard & (rnd | stky | lsb);  // RNE
      3'b001:  round_up = 1'b0;  // RTZ
      3'b010:  round_up = result_sign & (guard | rnd | stky);  // RDN
      3'b011:  round_up = !result_sign & (guard | rnd | stky);  // RUP
      3'b100:  round_up = guard;  // RMM
      default: round_up = guard & (rnd | stky | lsb);
    endcase
    // norm_mant[55:3] = 53-bit significand with hidden at [52] of this slice.
    // Adding round_up into a 54-bit result lets carry propagate into [53].
    sig53_rounded = {1'b0, norm_mant[55:3]} + {53'd0, round_up};
  end

  // Post-round carry normalisation
  // check sig53_rounded[53] (carry bit), not [52] (hidden bit).
  // sig53_rounded[53]=1 means the rounding increment caused an overflow
  // of the 53-bit significand; right-shift by 1, increment exponent.

  logic [12:0] final_exp;
  logic [51:0] final_frac;

  always_comb begin
    if (sig53_rounded[53]) begin
      // Carry-out: sig53_rounded[53:1] gives 53 bits with hidden at [52]
      final_exp  = norm_exp + 13'sd1;
      final_frac = sig53_rounded[52:1];
    end else begin
      // No carry: sig53_rounded[52:0] is the 53-bit result, frac = [51:0]
      final_exp  = norm_exp;
      final_frac = sig53_rounded[51:0];
    end
  end


  // Output mux (double-precision)
  logic of_flag;
  assign of_flag = (final_exp > 13'd2046);

  logic [63:0] d_result;
  logic [ 4:0] d_fflags;

  always_comb begin
    d_result = 64'd0;
    d_fflags = 5'b0;

    if (!en) begin
      d_result = 64'd0;

    end else if (is_snan_a || is_snan_b) begin
      d_result    = QNAN;
      d_fflags[4] = 1'b1;   // NV

    end else if (is_nan_a || is_nan_b) begin
      d_result = QNAN;

    end else if ((is_inf_a && is_zero_b) || (is_zero_a && is_inf_b)) begin
      d_result    = QNAN;
      d_fflags[4] = 1'b1;   // NV: 0 × ∞

    end else if (is_inf_a || is_inf_b) begin
      d_result = result_sign ? INF_NEG : INF_POS;

    end else if (is_zero_a || is_zero_b) begin
      d_result = {result_sign, 63'd0};

    end else if (of_flag) begin
      unique case (fp_rm)
        3'b000:  d_result = result_sign ? INF_NEG : INF_POS;
        3'b001:  d_result = result_sign ? MAX_FIN_NEG : MAX_FIN_POS;
        3'b010:  d_result = result_sign ? INF_NEG : MAX_FIN_POS;
        3'b011:  d_result = result_sign ? MAX_FIN_NEG : INF_POS;
        3'b100:  d_result = result_sign ? INF_NEG : INF_POS;
        default: d_result = result_sign ? INF_NEG : INF_POS;
      endcase
      d_fflags[2] = 1'b1;  // OF
      d_fflags[0] = 1'b1;  // NX

    // end else if (final_exp <= -13'sd1022) begin
    end else if (final_exp < 13'd1) begin
      // Underflow: flush to zero (subnormal support left as TODO per original)
      d_result    = {result_sign, 63'd0};
      d_fflags[1] = 1'b1;   // UF
      d_fflags[0] = 1'b1;   // NX

    end else begin
      // d_result    = {result_sign, 11'(final_exp + 13'sd1023), final_frac};
      d_result = {result_sign, final_exp[10:0], final_frac};
      d_fflags[0] = nx_flag;
    end
  end

  // S/D final output mux
  always_comb begin
    result = (en && fp_fmt == 2'b00) ? d_to_s_nanbox(d_result, fp_rm) : d_result;
    fflags = d_fflags;
  end

endmodule


`endif  // FPU_MUL_SV
