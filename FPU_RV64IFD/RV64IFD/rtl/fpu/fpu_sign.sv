`timescale 1ns / 1ps

`ifndef FPU_SIGN_SV
`define FPU_SIGN_SV

`include "isa_pkg.sv"
import isa_pkg::*;

// fpu_sign.sv — FSGNJ / FSGNJN / FSGNJX for both single and double precision.
//
// Sign injection is pure bit manipulation (IEEE 754 §5.5.1):
//   FSGNJ  : result = { sign(b),    |a[fmt-2:0] }
//   FSGNJN : result = { ~sign(b),   |a[fmt-2:0] }
//   FSGNJX : result = { sign(a)^sign(b), |a[fmt-2:0] }
//
// fp_fmt: FP_FMT_S (0) operates on bits [31:0] and NaN-boxes the result into 64.
//         FP_FMT_D (1) operates on all 64 bits.
//
// @Note NaN boxing: for single-precision results stored in 64-bit fp registers,
//   the upper 32 bits must be all-ones per RV spec §11.3 (§22.1.2 warning tag
//   on fpu_top.sv is addressed here).
module fpu_sign (
    input  logic            en,
    input  logic [FLEN-1:0] operand_a,
    input  logic [FLEN-1:0] operand_b,
    input  logic [1:0]      sgn_op,   // 00=FSGNJ 01=FSGNJN 10=FSGNJX
    input  logic [1:0]      fp_fmt,   // FP_FMT_S or FP_FMT_D
    output logic [FLEN-1:0] result
);

  logic sign_a_d, sign_b_d;
  logic sign_a_s, sign_b_s;
  logic new_sign_d, new_sign_s;

  // Double-precision sign bits
  assign sign_a_d = operand_a[63];
  assign sign_b_d = operand_b[63];

  // Single-precision sign bits (bit 31 of NaN-boxed value)
  assign sign_a_s = operand_a[31];
  assign sign_b_s = operand_b[31];

  always_comb begin
    unique case (sgn_op)
      2'b00: begin new_sign_d = sign_b_d; new_sign_s = sign_b_s; end          // FSGNJ
      2'b01: begin new_sign_d = ~sign_b_d; new_sign_s = ~sign_b_s; end        // FSGNJN
      2'b10: begin new_sign_d = sign_a_d ^ sign_b_d;                          // FSGNJX
                   new_sign_s = sign_a_s ^ sign_b_s; end
      default: begin new_sign_d = sign_b_d; new_sign_s = sign_b_s; end
    endcase
  end

  always_comb begin
    result = '0;
    if (en) begin
      if (fp_fmt == FP_FMT_D)
        result = {new_sign_d, operand_a[62:0]};
      else begin
        // FP_FMT_S: NaN-box upper 32 bits, inject sign into bit 31
        result = {32'hFFFF_FFFF, new_sign_s, operand_a[30:0]};
      end
    end
  end

endmodule

`endif // FPU_SIGN_SV
