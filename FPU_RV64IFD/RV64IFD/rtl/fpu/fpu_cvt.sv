// =============================================================================
// fpu_cvt.sv — IEEE 754 Double-Precision Convert
//
// Implements RV64D FCVT variants (combinational):
//   Float → Int:   FCVT.W.D / FCVT.WU.D / FCVT.L.D / FCVT.LU.D
//   Int   → Float: FCVT.D.W / FCVT.D.WU / FCVT.D.L / FCVT.D.LU
//
// cvt_to_int : 1 = float→int, 0 = int→float
// cvt_signed : 1 = signed int, 0 = unsigned int
// cvt_word   : 1 = 32-bit operand (W/WU), 0 = 64-bit (L/LU)
//
// =============================================================================


`ifndef FPU_CVT_SV
`define FPU_CVT_SV

`timescale 1ns / 1ps

module fpu_cvt (
    input  logic        en,
    input  logic [1:0]       fp_fmt,     // FP_FMT_S or FP_FMT_D
    input  logic        cvt_to_int,  // 1=float→int, 0=int→float
    input  logic        cvt_signed,  // 1=signed int, 0=unsigned
    input  logic        cvt_word,    // 1=32-bit op, 0=64-bit op
    input  logic [ 2:0] fp_rm,
    input  logic [63:0] operand_a,
    output logic [63:0] result,
    output logic [ 4:0] fflags
);


  function automatic logic [63:0] s_to_d(input logic [31:0] s);
    logic sign; logic [7:0] se; logic [22:0] sf;
    sign = s[31]; se = s[30:23]; sf = s[22:0];
    if (se == 8'hFF && sf != 23'd0) return 64'h7FF8_0000_0000_0000;
    if (se == 8'hFF)                return {sign, 11'h7FF, 52'd0};
    if (se == 8'd0 && sf == 23'd0)  return {sign, 63'd0};
    return {sign, 11'(int'(se) - 127 + 1023), sf, 29'd0};
  endfunction

  function automatic logic [63:0] d_to_s_nanbox(
      input logic [63:0] d, input logic [2:0] rm);
    logic ds; logic [10:0] de; logic [51:0] df;
    logic [7:0] se; logic [22:0] sf;
    logic signed [12:0] ue; logic guard,rnd,stky,lsb,rup; logic [23:0] sig24;
    ds = d[63]; de = d[62:52]; df = d[51:0];
    if (de == 11'h7FF && df != 52'd0)
      return {32'hFFFF_FFFF, 1'b0, 8'hFF, 23'h400000};
    if (de == 11'h7FF) return {32'hFFFF_FFFF, ds, 8'hFF, 23'd0};
    if (de == 11'd0)   return {32'hFFFF_FFFF, ds, 31'd0};
    ue   = $signed({2'b0, de}) - 13'sd1023;
    guard = df[28]; rnd = df[27]; stky = |df[26:0]; lsb = df[29];
    unique case (rm)
      3'b000: rup = guard & (rnd | stky | lsb);
      3'b001: rup = 1'b0;
      3'b010: rup = ds & (guard | rnd | stky);
      3'b011: rup = !ds & (guard | rnd | stky);
      3'b100: rup = guard;
      default: rup = guard & (rnd | stky | lsb);
    endcase
    sig24 = {1'b0, df[51:29]} + {23'd0, rup};
    if (ue > 13'sd127)  return {32'hFFFF_FFFF, ds, 8'hFF, 23'd0};
    if (ue < -13'sd126) return {32'hFFFF_FFFF, ds, 31'd0};
    if (sig24[23]) begin se = 8'(ue + 13'sd1 + 13'sd127); sf = sig24[22:0]; end
    else           begin se = 8'(ue + 13'sd127);           sf = sig24[22:0]; end
    return {32'hFFFF_FFFF, ds, se, sf};
  endfunction

  localparam logic [63:0] QNAN = 64'h7FF8_0000_0000_0000;

  // For float→int: upcast S to D so the same unpack/convert logic handles both
  logic [63:0] opa_d;
  always_comb
    opa_d = (fp_fmt == 2'b00) ? s_to_d(operand_a[31:0]) : operand_a;

  // Unpack float input (used for float→int path)
  logic        sign_f;
  logic [10:0] exp_biased;
  logic [52:0] mant;
  logic is_nan, is_inf, is_zero;

  assign sign_f     = opa_d[63];
  assign exp_biased = opa_d[62:52];
  assign mant       = {(exp_biased != 11'd0), opa_d[51:0]};
  assign is_nan     = (exp_biased == 11'h7FF) && (opa_d[51:0] != 52'd0);
  assign is_inf     = (exp_biased == 11'h7FF) && (opa_d[51:0] == 52'd0);
  assign is_zero    = (exp_biased == 11'd0) && (opa_d[51:0] == 52'd0);

  // Saturation constants for each variant
  localparam logic [63:0] SAT_I32_POS = 64'h0000_0000_7FFF_FFFF;
  localparam logic [63:0] SAT_I32_NEG = 64'hFFFF_FFFF_8000_0000;
  localparam logic [63:0] SAT_U32_MAX = 64'h0000_0000_FFFF_FFFF;
  localparam logic [63:0] SAT_U32_ZERO = 64'h0000_0000_0000_0000;
  localparam logic [63:0] SAT_I64_POS = 64'h7FFF_FFFF_FFFF_FFFF;
  localparam logic [63:0] SAT_I64_NEG = 64'h8000_0000_0000_0000;
  localparam logic [63:0] SAT_U64_MAX = 64'hFFFF_FFFF_FFFF_FFFF;


  // -------------------------------------------------------------------------
  // Float → Int
  // -------------------------------------------------------------------------
  // Unbiased exponent
  logic signed [12:0] exp_unbiased;
  assign exp_unbiased = $signed({2'b0, exp_biased}) - 13'sd1023;

  logic [63:0] int_result;
  logic int_nv, int_nx;


  always_comb begin
    int_result = 64'd0;
    int_nv     = 1'b0;
    int_nx     = 1'b0;

    if (is_nan || is_inf) begin
      // NaN and Inf → saturate, raise NV
      int_nv = 1'b1;
      if (cvt_word) begin
        if (cvt_signed) int_result = sign_f ? SAT_I32_NEG : SAT_I32_POS;
        else int_result = sign_f ? SAT_U32_ZERO : SAT_U32_MAX;
      end else begin
        if (cvt_signed) int_result = sign_f ? SAT_I64_NEG : SAT_I64_POS;
        else int_result = sign_f ? SAT_U32_ZERO : SAT_U64_MAX;
      end

    end else if (is_zero || (exp_unbiased < 13'sd0)) begin
      // Zero or |value| < 1.0 → result is 0; inexact if not exactly zero
      int_result = 64'd0;
      int_nx     = !is_zero;

    end else begin
      // Normal finite value: magnitude >= 1.0
      // Place the 53-bit significand at the correct integer bit position.
      // The integer value is:  mant >> (52 - exp_unbiased)   if exp <= 52
      //                        mant << (exp_unbiased - 52)   if exp >  52
      logic [63:0] magnitude;
      logic [63:0] lost_mask;
      logic [ 6:0] shift;

      magnitude = 64'd0;
      int_nx    = 1'b0;

      if (exp_unbiased >= 13'sd63) begin
        // Overflow for both signed and unsigned 64-bit
        int_nv = 1'b1;
        if (cvt_word) begin
          magnitude = cvt_signed ? (sign_f ? SAT_I32_NEG : SAT_I32_POS)
                                 : (sign_f ? SAT_U32_ZERO : SAT_U32_MAX);
        end else begin
          // For signed: -2^63 is representable (exp=63, mant=1.0, sign=1)
          if (cvt_signed && sign_f && (exp_unbiased == 13'sd63) && (operand_a[51:0] == 52'd0)) begin
            // Exactly -2^63: valid, representable
            int_nv    = 1'b0;
            magnitude = SAT_I64_NEG;
          end else begin
            magnitude = cvt_signed ? (sign_f ? SAT_I64_NEG : SAT_I64_POS) : SAT_U64_MAX;
          end
        end
        int_result = magnitude;

      end else if (exp_unbiased >= 13'sd52) begin
        // No fractional part: exact left-shift
        shift     = 7'(exp_unbiased) - 7'd52;
        magnitude = {11'd0, mant} << shift;
        int_nx    = 1'b0;

        // Sign
        if (cvt_signed) int_result = sign_f ? (~magnitude + 64'd1) : magnitude;
        else int_result = sign_f ? 64'd0 : magnitude;

        // Range check for word operations
        if (cvt_word) begin
          if (cvt_signed && ($signed(
                  int_result
              ) > $signed(
                  SAT_I32_POS
              ) || $signed(
                  int_result
              ) < $signed(
                  SAT_I32_NEG
              ))) begin
            int_nv     = 1'b1;
            int_result = sign_f ? SAT_I32_NEG : SAT_I32_POS;
          end else if (!cvt_signed && (int_result > SAT_U32_MAX)) begin
            int_nv     = 1'b1;
            int_result = sign_f ? SAT_U32_ZERO : SAT_U32_MAX;
          end
        end

      end else begin
        // Fractional bits present: right-shift
        shift     = 7'd52 - 7'(exp_unbiased);
        lost_mask = (64'd1 << shift) - 64'd1;
        int_nx    = |({11'd0, mant} & lost_mask);
        magnitude = {11'd0, mant} >> shift;

        // Sign
        if (cvt_signed) int_result = sign_f ? (~magnitude + 64'd1) : magnitude;
        else int_result = sign_f ? 64'd0 : magnitude;

        // Range check for word operations
        if (cvt_word) begin
          if (cvt_signed && ($signed(
                  int_result
              ) > $signed(
                  SAT_I32_POS
              ) || $signed(
                  int_result
              ) < $signed(
                  SAT_I32_NEG
              ))) begin
            int_nv     = 1'b1;
            int_result = sign_f ? SAT_I32_NEG : SAT_I32_POS;
          end else if (!cvt_signed && (int_result > SAT_U32_MAX)) begin
            int_nv     = 1'b1;
            int_result = sign_f ? SAT_U32_ZERO : SAT_U32_MAX;
          end
        end

        // 64-bit signed overflow check: negative results that wrapped
        if (!cvt_word && cvt_signed && !sign_f && int_result[63]) begin
          int_nv     = 1'b1;
          int_result = SAT_I64_POS;
        end
        if (!cvt_word && cvt_signed && sign_f && !int_result[63] && int_result != 64'd0) begin
          int_nv     = 1'b1;
          int_result = SAT_I64_NEG;
        end
      end
    end
  end


  // -------------------------------------------------------------------------
  // Int → Float
  // -------------------------------------------------------------------------
  logic [63:0] float_result;
  logic        float_nx;


  always_comb begin

    logic [63:0] mag;
    logic        neg;
    logic [ 6:0] msb_pos;  // position of leading 1 in mag [63..0]
    logic [10:0] f_exp;
    logic [63:0] frac_bits;  // bits below the hidden bit
    logic [51:0] f_frac;
    logic        round_up;

    float_result = 64'd0;
    float_nx     = 1'b0;

    // Step 1: sign and magnitude

    if (cvt_word) begin
      // 32-bit input; sign-extend for signed, zero-extend for unsigned
      if (cvt_signed) mag = {{32{operand_a[31]}}, operand_a[31:0]};
      else mag = {32'd0, operand_a[31:0]};
    end else begin
      mag = operand_a;
    end

    neg = cvt_signed && mag[63];
    if (neg) mag = ~mag + 64'd1;  // two's complement magnitude

    if (mag == 64'd0) begin
      float_result = 64'd0;

    end else begin
      // Find MSB position (leading 1)
      msb_pos = 7'd0;
      for (int i = 63; i >= 0; i--) begin
        if (mag[i]) begin
          msb_pos = 7'(i);
          break;
        end
      end

      // Biased exponent: 1023 + msb_pos
      f_exp = 11'd1023 + 11'(msb_pos);

      // Extract fraction: 52 bits below the hidden bit at msb_pos
      if (msb_pos >= 7'd52) begin
        // Shift right: frac = mag[(msb_pos-1) -: 52], round from remaining bits
        frac_bits = mag << (7'd63 - msb_pos);  // align hidden to bit63
        f_frac    = frac_bits[62:11];  // 52 bits
        // Round: guard=frac_bits[10], sticky=|frac_bits[9:0]
        round_up  = frac_bits[10] & (frac_bits[9] | (|frac_bits[8:0]) | f_frac[0]);
        float_nx  = frac_bits[10] | (|frac_bits[9:0]);
        if (round_up) begin
          logic [52:0] f_frac_inc;
          f_frac_inc = {1'b0, f_frac} + 53'd1;
          if (f_frac_inc[52]) begin
            f_frac = 52'd0;
            f_exp  = f_exp + 11'd1;  // carry into exponent
          end else begin
            f_frac = f_frac_inc[51:0];
          end
        end
      end else begin
        // Shift left: exact, no rounding needed
        f_frac   = mag[51:0] << (7'd52 - msb_pos);
        float_nx = 1'b0;
        round_up = 1'b0;
      end

      float_result = {neg, f_exp, f_frac};
    end
  end

  // Output mux
  always_comb begin
    result = 64'd0;
    fflags = 5'b0;

    if (!en) begin
      result = 64'd0;
    end else if (cvt_to_int) begin
      result    = int_result;
      fflags[4] = int_nv;
      fflags[0] = int_nx & !int_nv;
    end else begin
      // Int → float: pack to S or D depending on fp_fmt
      if (fp_fmt == 2'b00)
        result = d_to_s_nanbox(float_result, fp_rm);
      else
        result = float_result;
      fflags[0] = float_nx;
    end
  end

endmodule

`endif  // FPU_CVT_SV
