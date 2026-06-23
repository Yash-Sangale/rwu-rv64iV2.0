// =============================================================================
// alu_top.sv — RV64I ALU Top
//
// Structural wrapper. Contains:
//   alu_ctrl    — decodes instruction_t into per-unit control signals
//   (adder)     — inline: add/subtract with carry and overflow, 64 and 32-bit
//   (logic)     — inline: AND / OR / XOR / LUI (trivial, not worth a submodule)
//   shifter     — barrel shifter (SLL/SRL/SRA + word variants)
//   comparator  — SLT/SLTU + branch condition flags
//   mul_div     — RV64M multiply/divide stub
//
// Why the adder and logic unit are inline:
//   They each consist of one or two lines of logic and would add more
//   glue code than implementation code if split out. The ctrl/data
//   boundary is already clean — alu_ctrl owns the decode, alu_top owns
//   the small combinational ops directly.
//
// Port contract (unchanged from original alu_top.sv):
//   The external interface is identical to the original monolithic ALU.
//   core.sv, tb_alu.sv, and any future pipeline stages need no changes.
//
// Additional outputs vs original:
//   flag_eq / flag_lt_s / flag_lt_u — branch condition flags promoted from
//   comparator so core.sv can read them directly instead of re-implementing
//   the same comparison. The original zero/negative/overflow/carry are kept
//   for full backward compatibility.
//   clk / rst_n / muldiv_* — wired through to mul_div stub, ignored until
//   RV64M is enabled. Pass clk/rst_n from core; tie muldiv_valid_in low.
// =============================================================================

`ifndef ALU_TOP_SV
`define ALU_TOP_SV

`timescale 1ns/1ps

`include "isa_pkg.sv"
`include "alu_ctrl.sv"
`include "shifter.sv"
`include "comparator.sv"
`include "mul_div.sv"

import isa_pkg::*;

module alu_top (
    // --- Primary inputs 
    input  instruction_t      inst,
    input  logic [63:0]  operand_a,
    input  logic [63:0]  operand_b,

    // --- Primary result 
    output logic [63:0]  result,

    // --- Status flags 
    output logic         zero,
    output logic         negative,
    output logic         overflow,
    output logic         carry,

    // --- Branch condition flags ( eliminates duplicate logic in core.sv) ---
    output logic         flag_eq,
    output logic         flag_lt_s,
    output logic         flag_lt_u,

    // --- Mul/div handshake (stub, no-op until RV64M enabled) ---
    input  logic         clk,
    input  logic         rst_n,
    input  logic         muldiv_valid_in,
    output logic         muldiv_ready,
    output logic         muldiv_valid_out
);

  // =========================================================================
  // Control unit
  // =========================================================================
  logic        adder_en, adder_sub, adder_word;
  logic_sel_t  logic_sel;
  logic        shift_en, shift_left, shift_arith, shift_word;
  logic        cmp_en, cmp_signed;
  logic        muldiv_en;
  logic [2:0]  muldiv_op;
  res_sel_t    res_sel;

  alu_ctrl u_ctrl (
      .inst          (inst),
      .adder_en    (adder_en),
      .adder_sub   (adder_sub),
      .adder_word  (adder_word),
      .logic_sel   (logic_sel),
      .shift_en    (shift_en),
      .shift_left  (shift_left),
      .shift_arith (shift_arith),
      .shift_word  (shift_word),
      .cmp_en      (cmp_en),
      .cmp_signed  (cmp_signed),
      .muldiv_en   (muldiv_en),
      .muldiv_op   (muldiv_op),
      .res_sel     (res_sel)
  );

  // =========================================================================
  // Adder  (inline — ADD / SUB / ADDW / SUBW)
  // =========================================================================
  logic [64:0] add_full;
  logic [63:0] add_result;

  always_comb begin
    add_full   = '0;
    add_result = '0;
    if (adder_word) begin
      logic [32:0] add32;
      add32      = adder_sub
                   ? {1'b0, operand_a[31:0]} - {1'b0, operand_b[31:0]}
                   : {1'b0, operand_a[31:0]} + {1'b0, operand_b[31:0]};
      add_full   = {32'b0, add32};
      add_result = {{32{add32[31]}}, add32[31:0]};
    end else begin
      add_full   = adder_sub
                   ? {1'b0, operand_a} - {1'b0, operand_b}
                   : {1'b0, operand_a} + {1'b0, operand_b};
      add_result = add_full[63:0];
    end
  end

  // =========================================================================
  // Logic unit  (inline — AND / OR / XOR / LUI)
  // =========================================================================
  logic [63:0] logic_result;

  always_comb begin
    unique case (logic_sel)
      LOGIC_AND: logic_result = operand_a & operand_b;
      LOGIC_OR:  logic_result = operand_a | operand_b;
      LOGIC_XOR: logic_result = operand_a ^ operand_b;
      LOGIC_LUI: logic_result = operand_b;
      default:   logic_result = '0;
    endcase
  end

  // =========================================================================
  // Shifter
  // =========================================================================
  logic [63:0] shift_result;

  shifter u_shifter (
      .operand_a    (operand_a),
      .shift_amt_in (operand_b),
      .shift_left   (shift_left),
      .shift_arith  (shift_arith),
      .shift_word   (shift_word),
      .result       (shift_result)
  );

  // =========================================================================
  // Comparator
  // =========================================================================
  logic [63:0] cmp_result;

  comparator u_cmp (
      .operand_a  (operand_a),
      .operand_b  (operand_b),
      .cmp_signed (cmp_signed),
      .lt_result  (cmp_result),
      .flag_eq    (flag_eq),
      .flag_lt_s  (flag_lt_s),
      .flag_lt_u  (flag_lt_u)
  );

  // =========================================================================
  // Mul/div stub
  // =========================================================================
  logic [63:0] muldiv_result;

  mul_div u_muldiv (
      .clk       (clk),
      .rst_n     (rst_n),
      .en        (muldiv_en),
      .op        (muldiv_op),
      .operand_a (operand_a),
      .operand_b (operand_b),
      .valid_in  (muldiv_valid_in),
      .ready_out (muldiv_ready),
      .valid_out (muldiv_valid_out),
      .result    (muldiv_result)
  );

  // =========================================================================
  // Result mux
  // =========================================================================
  always_comb begin
    unique case (res_sel)
      SEL_ADDER:   result = add_result;
      SEL_LOGIC:   result = logic_result;
      SEL_SHIFT:   result = shift_result;
      SEL_COMPARE: result = cmp_result;
      SEL_MULDIV:  result = muldiv_result;
      SEL_PASSA:   result = operand_a;
      default:     result = '0;
    endcase
  end

  // =========================================================================
  // Status flags
  // =========================================================================
  assign zero     = (result == '0);
  assign negative = result[63];
  assign carry    = add_full[64];

  assign overflow = adder_en ? (
      adder_sub
      ? ( operand_a[63] & ~operand_b[63] & ~result[63])
      | (~operand_a[63] &  operand_b[63] &  result[63])
      : (~operand_a[63] & ~operand_b[63] &  result[63])
      | ( operand_a[63] &  operand_b[63] & ~result[63])
  ) : 1'b0;

endmodule

`endif // ALU_TOP_SV
