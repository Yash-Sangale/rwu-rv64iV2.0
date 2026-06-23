`timescale 1ns/1ps

`ifndef SHIFTER_SV
`define SHIFTER_SV

// =============================================================================
// shifter.sv — Barrel Shifter
//
// Handles all six RV64I shift instructions:
//   SLL  SLLW   left logical         (64-bit and 32-bit word)
//   SRL  SRLW   right logical
//   SRA  SRAW   right arithmetic
//
// Purely combinational. No clock, no reset, no enable gating — alu_top only
// connects this when shift_en is asserted; the result is ignored otherwise.
//
// Design notes:
//   - Word ops (shift_word=1) operate on operand_a[31:0] and use only
//     shift_amt[4:0]. The 32-bit result is sign-extended to 64 bits.
//   - Arithmetic right shift is implemented with $signed cast, which every
//     synthesiser handles correctly and tools like Verilator/xsim verify.
//   - The shift amount input is the full 64-bit operand_b; this module
//     extracts the relevant bits — 6 for 64-bit ops, 5 for word ops.
// =============================================================================

module shifter (
    input  logic [63:0]  operand_a,    // value to be shifted
    input  logic [63:0]  shift_amt_in, // raw operand_b — we extract [5:0]/[4:0]

    input  logic         shift_left,   // 1 = SLL/SLLW, 0 = SRL/SRA/SRLW/SRAW
    input  logic         shift_arith,  // 1 = arithmetic right (SRA/SRAW), 0 = logical
    input  logic         shift_word,   // 1 = 32-bit word op (SLLW/SRLW/SRAW)

    output logic [63:0]  result        // shifted result, word-ops sign-extended
);

  // Extract shift amount — 5 bits for word ops, 6 bits for 64-bit ops
  logic [5:0] amt64;
  logic [4:0] amt32;
  assign amt64 = shift_amt_in[5:0];
  assign amt32 = shift_amt_in[4:0];

  // 32-bit intermediates for word operations
  logic [31:0] word_in;
  logic [31:0] word_shifted;
  assign word_in = operand_a[31:0];

  always_comb begin
    result       = '0;
    word_shifted = '0;

    if (shift_word) begin
      // --- 32-bit word shifts — result sign-extended to 64 ---
      if (shift_left) begin
        word_shifted = word_in << amt32;
      end else if (shift_arith) begin
        word_shifted = 32'($signed(word_in) >>> amt32);
      end else begin
        word_shifted = word_in >> amt32;
      end
      // Sign-extend bit 31 of the 32-bit result to fill bits [63:32]
      result = {{32{word_shifted[31]}}, word_shifted};

    end else begin
      // --- 64-bit shifts ---
      if (shift_left) begin
        result = operand_a << amt64;
      end else if (shift_arith) begin
        result = 64'($signed(operand_a) >>> amt64);
      end else begin
        result = operand_a >> amt64;
      end
    end
  end

endmodule

`endif // SHIFTER_SV
