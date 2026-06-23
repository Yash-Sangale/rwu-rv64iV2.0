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
// Exponent formula:
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
//    odd formula: ((U-1) >> 1) + 1023 = ((exp_a-1024) >> 1) + 1023
//     For exp_a=1024: (0>>1)+1023 = 1023  ← sqrt(2.0) ≈ 1.414, exp=0 ✓
//
// Rounding:
//   After computing Q (53-bit integer sqrt of mant_fixed), the remainder R
//   tells us whether the result is exact and which way to round.
//   For RNE: increment Q if R > Q (i.e., the true sqrt is closer to Q+1).
//   A conservative  approach: if R != 0 (inexact), set NX; use
//   standard GRS rounding against the remainder.
//   Implemented full RNE: round_up iff R*2 > Q (equivalently R > Q/2,
//   but using exact integer comparison: 2*R > Q after the final bit).
//   The extra half-bit check: round_up = (R << 1) > Q
// =============================================================================


`ifndef FPU_SQRT_SV
`define FPU_SQRT_SV 

`timescale 1ns / 1ps

`include "isa_pkg.sv"
import isa_pkg::*;

module fpu_sqrt (
    input  logic            en,
    input  logic [     1:0] fp_fmt,     // FP_FMT_S or FP_FMT_D
    input  logic [     2:0] fp_rm,
    input  logic [FLEN-1:0] operand_a,
    output logic [FLEN-1:0] result,
    output logic [     4:0] fflags
);


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

  logic [63:0] opa;
  always_comb opa = (fp_fmt == 2'b00) ? s_to_d(operand_a[31:0]) : operand_a;

  logic        sign_a;
  logic [10:0] exp_a;
  logic [52:0] mant_a;

  assign sign_a = opa[63];
  assign exp_a  = opa[62:52];
  assign mant_a = {(exp_a != 11'd0), opa[51:0]};

  logic is_nan_a, is_snan_a;
  logic is_inf_a, is_zero_a;

  assign is_nan_a  = (exp_a == 11'h7FF) && (opa[51:0] != 52'd0);
  assign is_snan_a = is_nan_a && !opa[51];
  assign is_inf_a  = (exp_a == 11'h7FF) && (operand_a[51:0] == 52'd0);
  assign is_zero_a = (exp_a == 11'd0) && (opa[51:0] == 52'd0);


  localparam logic [63:0] QNAN = 64'h7FF8_0000_0000_0000;

  // -------------------------------------------------------------------------
  // Exponent computation
  // odd-exponent formula:
  //   exp_odd_flag = exp_a[0] XOR exp_a_is_zero_unbiased[0]
  //   Unbiased parity: U = exp_a - 1023. U is odd iff (exp_a XOR 1023) is odd
  //   XOR 1023 (0b01111111111): flips bit 0, so parity of U = ~parity of exp_a
  //   U odd ↔ exp_a even (since 1023 is odd, and odd-odd=even, even-odd=odd)
  //   More simply: U[0] = exp_a[0] ^ 1 (since 1023[0]=1)
  //   So U is odd when exp_a is even.
  //
  //   For subnormals (exp_a=0): U = -1022 (even) → no special case needed here.
  // -------------------------------------------------------------------------

  // Unbiased exponent; handle odd exponent by pre-shifting mantissa
  logic        u_is_odd;  // unbiased exponent is odd
  logic [10:0] result_exp;  // biased result exponent
  logic [53:0] mant_input;  // 53 or 54 bits: mant_a or 2*mant_a
  logic [63:0] result_d;
  logic [ 4:0] fflags_d;

  // always_comb begin
  //   // Unbiased exponent U = exp_a - 1023; U[0] = exp_a[0] ^ 1023[0] = exp_a[0]^1
  //   u_is_odd = ~exp_a[0];  // exp_a[0]=1 → U even; exp_a[0]=0 → U odd

  //   if (u_is_odd) begin
  //     // U odd → use (2*mant_a) as significand, result_exp = (U-1)/2 + 1023
  //     // (U-1)/2 + 1023 = ((exp_a - 1023) - 1)/2 + 1023
  //     //                = (exp_a - 1024)/2 + 1023
  //     //                = (exp_a - 1024 + 2046) / 2   [avoiding underflow]
  //     //                = (exp_a + 1022) >> 1
  //     mant_input = {1'b0, mant_a} << 1;  // 2 * mant_a
  //     result_exp = (11'(exp_a) + 11'd1022) >> 1;
  //   end else begin
  //     // U even → result_exp = U/2 + 1023 = (exp_a - 1023)/2 + 1023
  //     //                      = (exp_a + 1023) >> 1
  //     mant_input = {1'b0, mant_a};  // mant_a as-is
  //     result_exp = (11'(exp_a) + 11'd1023) >> 1;
  //   end
  // end

  logic [11:0] exp_sum;

  always_comb begin
    u_is_odd = ~exp_a[0];

    if (u_is_odd) begin
      mant_input = {1'b0,mant_a} << 1;

      exp_sum    = {1'b0,exp_a} + 12'd1022;
      result_exp = exp_sum >> 1;

    end else begin
      mant_input = {1'b0,mant_a};

      exp_sum    = {1'b0,exp_a} + 12'd1023;
      result_exp = exp_sum >> 1;
    end
  end

  // -------------------------------------------------------------------------
  // Fixed-point sqrt
  //
  // We compute isqrt(mant_input << 52):
  //   mant_input is a 53/54-bit integer representing the normalised significand.
  //   Scaling by 2^52 gives us a 105/106-bit fixed-point value.
  //   isqrt of this is the 53-bit result with hidden at [52].
  //
  // mant_fixed = mant_input << 52  →  up to 106 bits
  // R (remainder) is one bit wider: 107 bits.
  // -------------------------------------------------------------------------

  logic [105:0] mant_fixed;
  logic [ 52:0] Q;  // sqrt result, 53 bits, hidden at [52]
  logic [106:0] R;  // remainder = mant_fixed - Q^2 (tracked incrementally)
  logic [106:0] cost;  // (2Q + 2^i) * 2^i

  always_comb begin
    mant_fixed = {mant_input, 52'b0};  // scale by 2^52, at most 106 bits
    Q          = 53'd0;
    R          = {1'b0, mant_fixed};  // initial remainder = mant_fixed

    // Bit-by-bit, MSB first (bit 52 = hidden, down to bit 0)
    for (int i = 52; i >= 0; i--) begin
      // cost = ({Q, 1'b1}) << i  =  (2*Q + 1) * 2^i
      // This is a 107-bit shift of a 54-bit value, safe since i <= 52.
      // cost = {107'({Q, 1'b1})} << i;
      cost = ({54'd0, Q} << (i + 1)) + (107'd1 << (2 * i));
      if (cost <= R) begin
        R = R - cost;
        Q[i] = 1'b1;
      end
    end
    // $display("SQRTDBG exp=%h mant=%h Q=%h R=%h", exp_a, mant_input, Q, R);

  end

  // -------------------------------------------------------------------------
  // Round
  //
  // Q[52] = hidden bit (always 1 for normal results from normal inputs).
  // Q[51:0] = fraction bits.
  // R  = remainder; if R=0, result is exact.
  //
  // For RNE: round up if remainder > Q (the midpoint condition):
  //   true sqrt = Q + R/mant_fixed_denominator; rounds up if R*2 > Q
  //   Equivalently: (R << 1) > {1'b0, Q}
  //
  // For RTZ: never round up.
  // For RDN: never round up (result is non-negative).
  // For RUP: round up if R != 0.
  // For RMM: round up if R*2 >= Q (ties away from zero).
  // -------------------------------------------------------------------------

  logic        nx_flag;
  logic        round_up;
  logic [53:0] Q_rounded;  // 54 bits to catch rounding carry

  always_comb begin
    nx_flag = (R != 107'd0);

    unique case (fp_rm)
      3'b000:  round_up = nx_flag & ((R << 1) > {1'b0, Q});  // RNE
      3'b001:  round_up = 1'b0;  // RTZ
      3'b010:  round_up = 1'b0;  // RDN (result ≥ 0)
      3'b011:  round_up = nx_flag;  // RUP
      3'b100:  round_up = nx_flag & ((R << 1) >= {1'b0, Q});  // RMM
      default: round_up = nx_flag & ((R << 1) > {1'b0, Q});
    endcase

    Q_rounded = {1'b0, Q} + {53'd0, round_up};
  end

  // Post-round carry: if rounding pushed us past 1.111...1 → 10.000...0
  // the result exponent increments by 1.
  logic [10:0] final_exp;
  logic [51:0] final_frac;

  always_comb begin
    if (Q_rounded[53]) begin
      // Carry: new significand = {1, 52'b0}, exponent + 1
      final_exp  = result_exp + 11'd1;
      final_frac = 52'd0;
    end else begin
      final_exp  = result_exp;
      final_frac = Q_rounded[51:0];  // drop hidden bit [52]
    end
  end

  // always_comb begin
  //   $display("PACKDBG exp_a=%h result_exp=%h Q=%h Qr=%h final_exp=%h final_frac=%h", exp_a,
  //            result_exp, Q, Q_rounded, final_exp, final_frac);
  // end

  // Output mux
  always_comb begin
    result_d = 64'd0;
    fflags_d = 5'b0;

    if (!en) begin
      result_d = 64'd0;

    end else if (is_snan_a) begin
      result_d    = QNAN;
      fflags_d[4] = 1'b1;   // NV

    end else if (is_nan_a) begin
      result_d = QNAN;

    end else if (sign_a && !is_zero_a) begin
      // sqrt of negative (non-zero) → NaN, invalid
      result_d    = QNAN;
      fflags_d[4] = 1'b1;

    end else if (is_inf_a) begin
      result_d = 64'h7FF0_0000_0000_0000;  // sqrt(+∞) = +∞

    end else if (is_zero_a) begin
      result_d = opa;  // sqrt(±0) = ±0

    end else begin
      result_d    = {1'b0, final_exp, final_frac};
      fflags_d[0] = nx_flag;
    end
  end

  // S/D output mux
  // @Note Avoids circular assign by packing from final_exp/final_frac directly.
  logic [63:0] s_result_sqrt;
  always_comb begin
    if (!en || is_nan_a || is_snan_a || is_inf_a || is_zero_a || (sign_a && !is_zero_a))
      s_result_sqrt = result_d;  // special cases already set correctly in D form → nanbox
    else
      // Repack single-precision from same normalised fields
      s_result_sqrt = {
        32'hFFFF_FFFF, 1'b0, 8'(int'(final_exp) - 1023 + 127), final_frac[51:29]
      };
  end

  always_comb begin
    fflags = fflags_d;

    if (!en) begin
      result = '0;

    end else if (fp_fmt == 2'b00) begin
      result = d_to_s_nanbox(result_d, fp_rm);

    end else begin
      result = result_d;
    end
  end

endmodule


`endif  // FPU_SQRT_SV
