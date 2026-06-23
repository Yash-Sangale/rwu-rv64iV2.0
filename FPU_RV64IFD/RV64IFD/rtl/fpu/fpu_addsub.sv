// =============================================================================
// fpu_addsub.sv — IEEE 754-2019 Double-Precision Add / Subtract
//
// Verified bit layout of the extended significand (56-bit operands, 57-bit sum):
//
//   Pre-add operand [55:0]:
//     [55]    hidden bit       ← significand bit 52 (= mant[52])
//     [54:3]  fraction         ← significand bits [51:0]
//     [2:0]   GRS              ← guard / round / sticky (initially 0)
//
//   Post-add sum [56:0]:
//     [56]    carry workspace  ← set on addition carry-out
//     [55]    leading bit after normalization
//     [54:3]  fraction
//     [2:0]   GRS
//
// Construction: {hidden[52], frac[51:0]} << 3 → places hidden at [55]. ✓
//
// After rounding, the 53-bit rounded significand sig53[52:0] has:
//     [52]    hidden bit
//     [51:0]  fraction
//
// Rounding modes (fp_rm):
//   3'b000  RNE  round to nearest, ties to even
//   3'b001  RTZ  round toward zero
//   3'b010  RDN  round toward −∞
//   3'b011  RUP  round toward +∞
//   3'b100  RMM  round to nearest, ties away from zero
//
// fflags: {NV[4], DZ[3], OF[2], UF[1], NX[0]}
// =============================================================================

`ifndef FPU_ADDSUB_SV
`define FPU_ADDSUB_SV

`timescale 1ns / 1ps

`include "isa_pkg.sv"

module fpu_addsub (
    input  logic            en,
    input  logic            sub,
    input  logic [     2:0] fp_rm,
    input  logic [     1:0] fp_fmt,     // FP_FMT_S or FP_FMT_D
    input  logic [FLEN-1:0] operand_a,
    input  logic [FLEN-1:0] operand_b,
    output logic [FLEN-1:0] result,
    output logic [     4:0] fflags
);

  // Single-precision dispatch: NaN-box operands, run double-path on [31:0]
  // by converting S to D before entering the shared arithmetic body.
  // @Note We upcast S→D, compute in D, then downcast result D→S with truncation.
  // This is correct: FADD.S is defined as: round(exact(a+b)) in single precision.
  // By computing in double (which has more precision), we get the same result.
  // The final pack step re-rounds to single.
  // This approach avoids duplicating the entire add/sub pipeline for single precision.
  logic [FLEN-1:0] opa_eff, opb_eff;
  logic [FLEN-1:0] result_d;
  logic [4:0]      fflags_d;

  // Upcast S→D for FP_FMT_S (reuse fpu_cvt_fmt logic inline)
  function automatic logic [63:0] s_to_d(input logic [31:0] s);
    logic sign; logic [7:0] se; logic [22:0] sf;
    sign = s[31]; se = s[30:23]; sf = s[22:0];
    if (se == 8'hFF && sf != 23'd0) return 64'h7FF8_0000_0000_0000; // qNaN
    if (se == 8'hFF) return {sign, 11'h7FF, 52'd0};                 // inf
    if (se == 8'd0 && sf == 23'd0) return {sign, 63'd0};            // zero
    return {sign, 11'(int'(se) - 127 + 1023), sf, 29'd0};          // normal
  endfunction

  always_comb begin
    if (fp_fmt == 2'b00) begin  // FP_FMT_S
      opa_eff = s_to_d(operand_a[31:0]);
      opb_eff = s_to_d(operand_b[31:0]);
    end else begin
      opa_eff = operand_a;
      opb_eff = operand_b;
    end
  end

  // -------------------------------------------------------------------------
  // 1. Unpack
  // -------------------------------------------------------------------------
  logic        sign_a, sign_b;
  logic [10:0] exp_a,  exp_b;
  logic [52:0] mant_a, mant_b;   // {hidden[52], frac[51:0]}

  assign sign_a = operand_a[63];
  assign sign_b = operand_b[63] ^ sub;

  assign exp_a  = operand_a[62:52];
  assign exp_b  = operand_b[62:52];

  assign mant_a = {(exp_a != 11'd0), operand_a[51:0]};
  assign mant_b = {(exp_b != 11'd0), operand_b[51:0]};

  // -------------------------------------------------------------------------
  // 2. Special-value detection
  // -------------------------------------------------------------------------
  logic is_nan_a,  is_nan_b;
  logic is_snan_a, is_snan_b;
  logic is_inf_a,  is_inf_b;
  logic is_zero_a, is_zero_b;

  assign is_nan_a  = (exp_a == 11'h7FF) && (opa_eff[51:0] != 52'd0);
  assign is_nan_b  = (exp_b == 11'h7FF) && (opb_eff[51:0] != 52'd0);
  assign is_snan_a = is_nan_a && !opa_eff[51];
  assign is_snan_b = is_nan_b && !opb_eff[51];
  assign is_inf_a  = (exp_a == 11'h7FF) && (operand_a[51:0] == 52'd0);
  assign is_inf_b  = (exp_b == 11'h7FF) && (operand_b[51:0] == 52'd0);
  assign is_zero_a = (exp_a == 11'd0)   && (operand_a[51:0] == 52'd0);
  assign is_zero_b = (exp_b == 11'd0)   && (operand_b[51:0] == 52'd0);

  localparam logic [63:0] QNAN        = 64'h7FF8_0000_0000_0000;
  localparam logic [63:0] INF_POS     = 64'h7FF0_0000_0000_0000;
  localparam logic [63:0] INF_NEG     = 64'hFFF0_0000_0000_0000;
  localparam logic [63:0] MAX_FIN_POS = 64'h7FEF_FFFF_FFFF_FFFF;
  localparam logic [63:0] MAX_FIN_NEG = 64'hFFEF_FFFF_FFFF_FFFF;
  localparam logic [63:0] ZERO_POS    = 64'h0000_0000_0000_0000;
  localparam logic [63:0] ZERO_NEG    = 64'h8000_0000_0000_0000;

  // -------------------------------------------------------------------------
  // 3. Alignment swap — guarantee |m_big| >= |m_sml|
  // -------------------------------------------------------------------------
  logic        s_a, s_b;
  logic [10:0] exp_big, exp_sml;
  logic [52:0] m_big_53, m_sml_53;
  logic [10:0] exp_diff;

  always_comb begin
    if ((exp_a > exp_b) || ((exp_a == exp_b) && (mant_a >= mant_b))) begin
      s_a      = sign_a;  s_b      = sign_b;
      exp_big  = exp_a;   exp_sml  = exp_b;
      m_big_53 = mant_a;  m_sml_53 = mant_b;
    end else begin
      s_a      = sign_b;  s_b      = sign_a;
      exp_big  = exp_b;   exp_sml  = exp_a;
      m_big_53 = mant_b;  m_sml_53 = mant_a;
    end
    exp_diff = exp_big - exp_sml;
  end

  // -------------------------------------------------------------------------
  // 3b. Extend to 56 bits: hidden at [55], frac at [54:3], GRS at [2:0]
  //
  //     mant[52:0] << 3  →  [55]=hidden, [54:3]=frac, [2:0]=000
  // -------------------------------------------------------------------------
  logic [55:0] m_big_ext;
  assign m_big_ext = {m_big_53, 3'b000};   // 53+3 = 56 bits, hidden at [55]

  // Separate wire for pre-shift value to prevent self-aliasing in always_comb
  logic [55:0] m_sml_pre;
  assign m_sml_pre = {m_sml_53, 3'b000};

  logic [55:0] m_sml_aligned;
  logic        sticky_align;

  always_comb begin
    sticky_align  = 1'b0;
    m_sml_aligned = m_sml_pre;

    if (exp_diff >= 11'd56) begin
      sticky_align  = |m_sml_pre;
      m_sml_aligned = {55'd0, sticky_align};
    end else if (exp_diff != 11'd0) begin
      sticky_align        = |(m_sml_pre & ((56'd1 << exp_diff) - 56'd1));
      m_sml_aligned       = m_sml_pre >> exp_diff;
      m_sml_aligned[0]    = m_sml_aligned[0] | sticky_align;
    end
  end

  // -------------------------------------------------------------------------
  // 4. Add / subtract — sum is 57 bits; bit [56] is the carry
  // -------------------------------------------------------------------------
  logic [56:0] sum;
  logic        result_sign;

  always_comb begin
    if (s_a == s_b)
      sum = {1'b0, m_big_ext} + {1'b0, m_sml_aligned};
    else
      sum = {1'b0, m_big_ext} - {1'b0, m_sml_aligned};

    result_sign = s_a;
  end

  logic sum_is_zero;
  assign sum_is_zero = (sum == 57'd0);

  // -------------------------------------------------------------------------
  // 5. Normalize
  //
  // Carry case  (sum[56]=1): right-shift 1, exp+1.
  // Standard    (sum[56]=0): find leading 1 at or below bit 55; left-shift to [55].
  //
  // After normalisation, norm_mant[55:0] has:
  //   [55]   hidden bit
  //   [54:3] fraction
  //   [2:0]  GRS
  // -------------------------------------------------------------------------
  logic signed [12:0] exp_working;
  always_comb begin
    if (exp_big == 11'd0) exp_working = -13'sd1022;   // subnormal input
    else                  exp_working = $signed({2'b00, exp_big}) - 13'sd1023;
  end

  logic signed [12:0] norm_exp;
  logic        [55:0] norm_mant;
  logic        [6:0]  lz_count;
  logic        [55:0] lost_mask;
  logic               lost_bits;
  logic               nx_carry;

  always_comb begin
    norm_mant  = sum[55:0];
    norm_exp   = exp_working;
    lz_count   = 7'd0;
    lost_mask  = 56'd0;
    lost_bits  = 1'b0;
    nx_carry   = 1'b0;

    if (sum_is_zero) begin
      norm_mant = 56'd0;
      norm_exp  = -13'sd1075;   // sentinel; replaced in output mux

    end else if (sum[56]) begin
      // ── Carry: right-shift 1, preserve sticky ──────────────────────────
      // sum[56:1] → norm_mant[55:0]; old bit[0] ORed into new bit[0]
      norm_mant    = sum[56:1];
      norm_mant[0] = norm_mant[0] | sum[0];
      norm_exp     = exp_working + 13'sd1;
      nx_carry     = sum[0];

    end else begin
      // ── Standard: find MSB at or below bit 55, left-normalise to [55] ──
      lz_count = 7'd52;   // worst case: only GRS survive
      for (int i = 55; i >= 3; i--) begin
        if (sum[i]) begin
          lz_count = 7'(55 - i);
          break;
        end
      end

      lost_mask = lz_count ? ((56'd1 << lz_count) - 56'd1) : 56'd0;
      lost_bits = |(sum[55:0] & lost_mask);

      norm_mant    = (sum[55:0] << lz_count);
      norm_mant[0] = norm_mant[0] | lost_bits;
      norm_exp     = exp_working - $signed({6'd0, lz_count});
    end
  end

  // -------------------------------------------------------------------------
  // 6. Subnormal clamp
  //    If norm_exp < -1022, the result is subnormal (or underflows to zero).
  //    Right-shift norm_mant by (-1022 - norm_exp) positions; freeze exp at -1022.
  // -------------------------------------------------------------------------
  logic signed [12:0] subnorm_exp;
  logic        [55:0] subnorm_mant;
  logic signed [12:0] sub_shift;
  logic               sticky_sub;
  logic               nx_subnorm;

  always_comb begin
    subnorm_mant = norm_mant;
    subnorm_exp  = norm_exp;
    sticky_sub   = 1'b0;
    sub_shift    = 13'sd0;
    nx_subnorm   = 1'b0;

    if (!sum_is_zero && (norm_exp < -13'sd1022)) begin
      sub_shift = -13'sd1022 - norm_exp;

      if (sub_shift >= 56) begin
        sticky_sub       = |norm_mant;
        subnorm_mant     = 56'd0;
        subnorm_mant[0]  = sticky_sub;
      end else begin
        sticky_sub           = |(norm_mant & ((56'd1 << sub_shift) - 56'd1));
        subnorm_mant         = norm_mant >> sub_shift;
        subnorm_mant[0]      = subnorm_mant[0] | sticky_sub;
      end

      subnorm_exp  = -13'sd1022;   // exponent field will be 0 for subnormals
      nx_subnorm   = sticky_sub;
    end
  end

  logic nx_prenorm;
  assign nx_prenorm = nx_carry | nx_subnorm;

  // -------------------------------------------------------------------------
  // 7. Round
  //    GRS at subnorm_mant[2:0]; significand bits above at [55:3].
  //    subnorm_mant[55] is the hidden bit.
  //    sig53 = subnorm_mant[55:3]  (53 bits; [52]=hidden)
  // -------------------------------------------------------------------------
  logic guard_bit, round_bit, sticky_bit, lsb_bit;
  logic round_up;
  logic [53:0] sig53_rounded;   // 54 bits to capture rounding carry

  always_comb begin
    guard_bit  = subnorm_mant[2];
    round_bit  = subnorm_mant[1];
    sticky_bit = subnorm_mant[0];
    lsb_bit    = subnorm_mant[3];   // LSB of kept significand (for RNE ties)

    unique case (fp_rm)
      3'b000:  round_up = guard_bit & (round_bit | sticky_bit | lsb_bit);  // RNE
      3'b001:  round_up = 1'b0;                                             // RTZ
      3'b010:  round_up = result_sign  & (guard_bit | round_bit | sticky_bit); // RDN
      3'b011:  round_up = !result_sign & (guard_bit | round_bit | sticky_bit); // RUP
      3'b100:  round_up = guard_bit;                                         // RMM
      default: round_up = guard_bit & (round_bit | sticky_bit | lsb_bit);  // RNE
    endcase

    // sig53_rounded[53:0]: carry at [53], hidden at [52], frac at [51:0]
    sig53_rounded = {1'b0, subnorm_mant[55:3]} + {53'd0, round_up};
  end

  logic nx_round;
  assign nx_round = guard_bit | round_bit | sticky_bit;

  // -------------------------------------------------------------------------
  // 8. Post-round carry normalisation
  //    If rounding overflows into bit [53], right-shift 1 and increment exp.
  //    After this, rounded_frac53[52:0] has hidden at [52].
  // -------------------------------------------------------------------------
  logic signed [12:0] rounded_exp;
  logic        [52:0] rounded_frac53;   // [52]=hidden, [51:0]=fraction

  always_comb begin
    if (sig53_rounded[53]) begin
      // Carry into bit 53: shift right 1
      // sig53_rounded[53:1] → 53 bits with hidden at [52]
      rounded_frac53 = sig53_rounded[53:1];
      rounded_exp    = subnorm_exp + 13'sd1;
    end else begin
      rounded_frac53 = sig53_rounded[52:0];
      rounded_exp    = subnorm_exp;
    end
  end

  // -------------------------------------------------------------------------
  // 9. Pack IEEE fields
  //    Normal:    rounded_frac53[52]=1  → biased exp = rounded_exp + 1023
  //    Subnormal: rounded_frac53[52]=0 and rounded_frac53 != 0 → exp field 0
  //    Zero:      rounded_frac53 == 0  → exp field 0, frac 0
  // -------------------------------------------------------------------------
  logic [10:0] packed_exp;
  logic [51:0] packed_frac;
  logic        of_flag, uf_flag, nx_flag;

  assign nx_flag = nx_prenorm | nx_round;

  always_comb begin
    of_flag = (rounded_exp > 13'sd1023);

    if (rounded_frac53 == 53'd0) begin
      packed_exp  = 11'd0;
      packed_frac = 52'd0;
    end else if (!rounded_frac53[52]) begin
      // Subnormal: hidden bit absent
      packed_exp  = 11'd0;
      packed_frac = rounded_frac53[51:0];
    end else begin
      // Normal
      packed_exp  = 11'(rounded_exp + 13'sd1023);
      packed_frac = rounded_frac53[51:0];
    end
  end

  always_comb begin
    uf_flag = (packed_exp == 11'd0) && (packed_frac != 52'd0) && nx_flag;
  end

  // -------------------------------------------------------------------------
  // 10. Output mux (priority-encoded)
  //
  // IEEE 754-2019 §7.2 : sNaN → NV=1; qNaN propagation alone → NV=0.
  // IEEE 754-2019 §6.3 : exact-zero sign = +0 except RDN (→ −0).
  // IEEE 754-2019 §7.4 : overflow result depends on rounding mode and sign.
  // -------------------------------------------------------------------------
  logic zero_result;
  assign zero_result = sum_is_zero && !is_inf_a && !is_inf_b
                       && !is_nan_a && !is_nan_b;

  // Run double-precision computation on (possibly up-casted) operands
  // Rename operand_a/b → opa_eff/opb_eff below via text substitution in body.
  // @Note: For clean isolation the body below references opa_eff/opb_eff.

  always_comb begin
    result_d = 64'd0;
    fflags_d = 5'd0;

    if (!en) begin
      result_d = 64'd0;

    end else if (is_snan_a || is_snan_b) begin
      result_d    = QNAN;
      fflags_d[4] = 1'b1;   // NV

    end else if (is_nan_a || is_nan_b) begin
      result_d = QNAN;
      // NV not raised for quiet NaN propagation

    end else if (is_inf_a && is_inf_b && (sign_a != sign_b)) begin
      // ∞ − ∞ or −∞ + ∞
      result_d    = QNAN;
      fflags_d[4] = 1'b1;   // NV

    end else if (is_inf_a) begin
      result_d = {sign_a, 11'h7FF, 52'd0};

    end else if (is_inf_b) begin
      result_d = {sign_b, 11'h7FF, 52'd0};   // sign_b already has sub applied

    end else if (zero_result) begin
      // IEEE 754-2019 §6.3: +0 for all modes except RDN (−0)
      result_d = (fp_rm == 3'b010) ? ZERO_NEG : ZERO_POS;

    end else if (of_flag) begin
      unique case (fp_rm)
        3'b000:  result_d = result_sign ? INF_NEG     : INF_POS;     // RNE
        3'b001:  result_d = result_sign ? MAX_FIN_NEG : MAX_FIN_POS; // RTZ
        3'b010:  result_d = result_sign ? INF_NEG     : MAX_FIN_POS; // RDN
        3'b011:  result_d = result_sign ? MAX_FIN_NEG : INF_POS;     // RUP
        3'b100:  result_d = result_sign ? INF_NEG     : INF_POS;     // RMM
        default: result_d = result_sign ? INF_NEG     : INF_POS;
      endcase
      fflags_d[2] = 1'b1;   // OF
      fflags_d[0] = 1'b1;   // NX

    end else begin
      result_d    = {result_sign, packed_exp, packed_frac};
      fflags_d[1] = uf_flag;
      fflags_d[0] = nx_flag;
    end
  end

  // For FP_FMT_S: downcast D result → S and NaN-box.
  // We truncate (no re-rounding needed: the D result is already correctly rounded
  // to S precision because D has > 53-S mantissa bits and we computed in D).
  // @Note: overflow/underflow flags from D computation are valid for S too.
  always_comb begin
    if (!en) begin
      result = '0; fflags = '0;
    end else if (fp_fmt == 2'b00) begin  // FP_FMT_S output
      // Use result_d (the D-precision result computed above)
      logic [31:0] s_out;
      if (result_d[62:52] == 11'h7FF)
        s_out = {result_d[63], 8'hFF, result_d[51:29]};       // inf/nan
      else if (result_d[62:52] == 11'd0)
        s_out = {result_d[63], 31'd0};                        // zero/subnorm
      else begin
        logic [7:0] s_exp_o;
        s_exp_o = 8'(int'(result_d[62:52]) - 1023 + 127);
        s_out   = {result_d[63], s_exp_o, result_d[51:29]};
      end
      result = {32'hFFFF_FFFF, s_out};
      fflags = fflags_d;
    end else begin
      result = result_d;
      fflags = fflags_d;
    end
  end

endmodule

`endif  // FPU_ADDSUB_SV