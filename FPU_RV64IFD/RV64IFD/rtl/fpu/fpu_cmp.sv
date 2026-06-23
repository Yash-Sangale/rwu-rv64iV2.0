`timescale 1ns/1ps

`ifndef FPU_CMP_SV
`define FPU_CMP_SV

// =============================================================================
// fpu_cmp.sv — IEEE 754 Double-Precision Comparison
//
// Implements FEQ.D / FLT.D / FLE.D  (RV64D, opcode OP_FP funct7=1010001)
// Result is an integer 0 or 1 in a 64-bit register (written to int regfile).
//
// cmp_op encoding matches fpu_ctrl.sv:
//   2'd0 = FEQ  (unordered → 0, invalid only for SNaN)
//   2'd1 = FLT  (unordered → 0, invalid)
//   2'd2 = FLE  (unordered → 0, invalid)
//
// IEEE comparison rules:
//   - NaN comparisons: always return 0; SNaN raises NV
//   - +0 == -0: true
//   - signed magnitude comparison for normal values
// =============================================================================

module fpu_cmp (
    input  logic         en,
    input  logic [1:0]       fp_fmt,     // FP_FMT_S or FP_FMT_D
    input  logic [1:0]   cmp_op,
    input  logic [63:0]  operand_a,
    input  logic [63:0]  operand_b,
    output logic [63:0]  result,
    output logic [4:0]   fflags
);


  function automatic logic [63:0] s_to_d(input logic [31:0] s);
    logic sign; logic [7:0] se; logic [22:0] sf;
    sign = s[31]; se = s[30:23]; sf = s[22:0];
    if (se == 8'hFF && sf != 23'd0) return 64'h7FF8_0000_0000_0000;
    if (se == 8'hFF)                return {sign, 11'h7FF, 52'd0};
    if (se == 8'd0 && sf == 23'd0)  return {sign, 63'd0};
    return {sign, 11'(int'(se) - 127 + 1023), sf, 29'd0};
  endfunction

  // Upcast S to D so the same comparison logic handles both precisions
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

  logic        sign_a, sign_b;
  logic [10:0] exp_a, exp_b;
  logic [51:0] frac_a, frac_b;

  assign sign_a = opa[63];
  assign sign_b = opb[63];
  assign exp_a  = opa[62:52];
  assign exp_b  = opb[62:52];
  assign frac_a = opa[51:0];
  assign frac_b = opb[51:0];

  logic is_nan_a, is_nan_b, is_snan_a, is_snan_b;
  logic is_zero_a, is_zero_b;

  assign is_nan_a  = (exp_a == 11'h7FF) && (frac_a != 52'd0);
  assign is_nan_b  = (exp_b == 11'h7FF) && (frac_b != 52'd0);
  assign is_snan_a = is_nan_a && !opa[51];
  assign is_snan_b = is_nan_b && !opb[51];
  assign is_zero_a = (opa[62:0] == 63'd0);
  assign is_zero_b = (opb[62:0] == 63'd0);

  // Magnitude comparison (ignoring sign)
  logic mag_lt, mag_eq;
  assign mag_eq = (opa[62:0] == opb[62:0]);
  assign mag_lt = (opa[62:0] <  opb[62:0]);

  // Signed comparison
  logic cmp_eq, cmp_lt;
  always_comb begin
    // +0 == -0
    cmp_eq = mag_eq || (is_zero_a && is_zero_b);

    if (sign_a && !sign_b)
      cmp_lt = !is_zero_a || !is_zero_b ? 1'b1 : 1'b0;  // neg < pos (unless both 0)
    else if (!sign_a && sign_b)
      cmp_lt = 1'b0;  // pos > neg
    else if (!sign_a)
      cmp_lt = mag_lt;       // both positive: normal magnitude
    else
      cmp_lt = !mag_lt && !mag_eq;  // both negative: reversed
  end

  always_comb begin
    result = '0;
    fflags = 5'b0;

    if (!en) begin
      result = '0;
    end else if (is_nan_a || is_nan_b) begin
      result    = 64'd0;
      // FEQ only raises NV for SNaN; FLT/FLE always raise NV for any NaN
      fflags[4] = (cmp_op == 2'd0) ? (is_snan_a | is_snan_b) : 1'b1;
    end else begin
      unique case (cmp_op)
        2'd0:    result = {63'd0, cmp_eq};        // FEQ
        2'd1:    result = {63'd0, cmp_lt};        // FLT
        2'd2:    result = {63'd0, cmp_lt | cmp_eq}; // FLE
        default: result = 64'd0;
      endcase
    end
  end

endmodule

`endif // FPU_CMP_SV
