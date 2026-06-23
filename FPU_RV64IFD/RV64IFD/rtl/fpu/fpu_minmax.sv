`timescale 1ns / 1ps

`ifndef FPU_MINMAX_SV
`define FPU_MINMAX_SV 

`include "isa_pkg.sv"
import isa_pkg::*;

// fpu_minmax.sv — FMIN / FMAX for single and double precision.
//
// IEEE 754-2019 §9.6 minNum / maxNum:
//   - If one operand is a quiet NaN and the other is a number, return the number.
//   - If both are NaN, return canonical qNaN; raise NV.
//   - SNaN always raises NV, returns canonical qNaN.
//   - -0 < +0 for both min and max.
//
// fp_fmt: single precision uses bits [31:0], NaN-boxes result into 64.
module fpu_minmax (
    input  logic            en,
    input  logic [FLEN-1:0] operand_a,
    input  logic [FLEN-1:0] operand_b,
    input  logic            min_sel,    // 0=FMIN, 1=FMAX
    input  logic [     1:0] fp_fmt,
    output logic [FLEN-1:0] result,
    output logic [     4:0] fflags
);

  localparam logic [63:0] D_QNAN = 64'h7FF8_0000_0000_0000;
  localparam logic [31:0] S_QNAN = 32'h7FC0_0000;

  // Double precision helpers
  function automatic logic d_is_nan(input logic [63:0] v);
    return (v[62:52] == 11'h7FF) && (v[51:0] != 52'd0);
  endfunction
  function automatic logic d_is_snan(input logic [63:0] v);
    return d_is_nan(v) && !v[51];
  endfunction

  // Signed less-than for double (handles -0/+0 correctly)
  function automatic logic d_lt(input logic [63:0] a, input logic [63:0] b);
    logic both_zero;
    both_zero = (a[62:0] == 63'd0) && (b[62:0] == 63'd0);
    if (both_zero) return 1'b0;
    if (a[63] && !b[63]) return 1'b1;  // neg < pos
    if (!a[63] && b[63]) return 1'b0;
    if (!a[63]) return a[62:0] < b[62:0];
    return a[62:0] > b[62:0];  // both negative: larger magnitude = smaller value
  endfunction

  // Single precision helpers (operate on bits [31:0])
  function automatic logic s_is_nan(input logic [31:0] v);
    return (v[30:23] == 8'hFF) && (v[22:0] != 23'd0);
  endfunction

  function automatic logic s_is_snan(input logic [31:0] v);
    return s_is_nan(v) && !v[22];
  endfunction

  function automatic logic s_lt(input logic [31:0] a, input logic [31:0] b);
    logic both_zero;
    both_zero = (a[30:0] == 31'd0) && (b[30:0] == 31'd0);
    if (both_zero) return 1'b0;
    if (a[31] && !b[31]) return 1'b1;
    if (!a[31] && b[31]) return 1'b0;
    if (!a[31]) return a[30:0] < b[30:0];
    return a[30:0] > b[30:0];
  endfunction

  always_comb begin
    result = '0;
    fflags = 5'b0;

    if (!en) begin
      result = '0;

    end else if (fp_fmt == FP_FMT_D) begin
      logic nan_a, nan_b, snan_a, snan_b;
      nan_a  = d_is_nan(operand_a);
      nan_b  = d_is_nan(operand_b);
      snan_a = d_is_snan(operand_a);
      snan_b = d_is_snan(operand_b);

      if (snan_a || snan_b) begin
        result    = D_QNAN;
        fflags[4] = 1'b1;  // NV
      end else if (nan_a && nan_b) begin
        result    = D_QNAN;
        fflags[4] = 1'b1;
      end else if (nan_a) begin
        result = operand_b;  // return the non-NaN
      end else if (nan_b) begin
        result = operand_a;
      end else begin
        logic a_lt_b;
        logic a_zero, b_zero;

        a_zero = (operand_a[62:0] == 0);
        b_zero = (operand_b[62:0] == 0);

        // SPECIAL CASE: signed zero tie-break (MUST BE BEFORE compare)
        if (a_zero && b_zero) begin
          if (min_sel) begin
            result = (operand_a[63]) ? operand_a : operand_b;  // FMIN: -0 wins
          end else begin
            result = (!operand_a[63]) ? operand_a : operand_b;  // FMAX: +0 wins
          end
        end else begin
          a_lt_b = d_lt(operand_a, operand_b);

          result = min_sel ? (a_lt_b ? operand_a : operand_b)  // FMIN
          : (a_lt_b ? operand_b : operand_a);  // FMAX
        end
      end

    end else begin  // FP_FMT_S — operate on [31:0]
      logic [31:0] sa, sb;
      logic nan_a, nan_b, snan_a, snan_b;
      logic [31:0] res32;
      sa = operand_a[31:0];
      sb = operand_b[31:0];
      nan_a = s_is_nan(sa);
      nan_b = s_is_nan(sb);
      snan_a = s_is_snan(sa);
      snan_b = s_is_snan(sb);


      if (snan_a || snan_b) begin
        res32     = S_QNAN;
        fflags[4] = 1'b1;
      end else if (nan_a && nan_b) begin
        res32     = S_QNAN;
        fflags[4] = 1'b1;
      end else if (nan_a) begin
        res32 = sb;
      end else if (nan_b) begin
        res32 = sa;
      end else begin
        logic a_lt_b;
        a_lt_b = s_lt(sa, sb);
        res32  = min_sel ? (a_lt_b ? sb : sa) : (a_lt_b ? sa : sb);
      end
      result = {32'hFFFF_FFFF, res32};  // NaN box
    end
  end

endmodule

`endif  // FPU_MINMAX_SV
