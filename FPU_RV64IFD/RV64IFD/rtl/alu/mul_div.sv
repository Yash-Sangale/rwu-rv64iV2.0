`timescale 1ns/1ps

`ifndef MUL_DIV_SV
`define MUL_DIV_SV

// =============================================================================
// mul_div.sv — RV64M Multiply / Divide Unit  (STUB)
//
// Currently a zero-latency stub that drives 0 on all outputs.
// alu_ctrl.sv never asserts muldiv_en for base RV64I ops, so this module
// has no effect on simulation or synthesis until you activate it.
//
// Activation checklist (RV64M extension):
//   1. Add INST_MUL / INST_MULH / INST_MULHSU / INST_MULHU /
//          INST_DIV / INST_DIVU / INST_REM / INST_REMU to isa_pkg.sv
//   2. Uncomment the corresponding alu_ctrl.sv case arms
//   3. Replace the stub logic below with a real implementation
//   4. For division: add a multi-cycle handshake (valid/ready) and
//      wire stall back to the core pipeline through core.sv
//
// Interface note:
//   valid_in / ready_out / valid_out implement a simple handshake that
//   is already plumbed through alu_top.sv for the future multi-cycle case.
//   In the stub, ready_out is always 1 and valid_out mirrors valid_in.
//
// Sub-operation encoding (muldiv_op — matches alu_ctrl.sv comments):
//   3'd0  MUL      lower 64 bits of 64×64 signed product
//   3'd1  MULH     upper 64 bits, signed × signed
//   3'd2  MULHSU   upper 64 bits, signed × unsigned
//   3'd3  MULHU    upper 64 bits, unsigned × unsigned
//   3'd4  DIV      signed quotient
//   3'd5  DIVU     unsigned quotient
//   3'd6  REM      signed remainder
//   3'd7  REMU     unsigned remainder
// =============================================================================

module mul_div (
    input  logic        clk,
    input  logic        rst_n,

    // Control
    input  logic        en,          // asserted by alu_ctrl when op is MUL/DIV
    input  logic [2:0]  op,          // sub-operation (see encoding above)

    // Data
    input  logic [63:0] operand_a,
    input  logic [63:0] operand_b,

    // Handshake (single-cycle for MUL, multi-cycle for DIV)
    input  logic        valid_in,
    output logic        ready_out,   // unit is ready to accept a new operation
    output logic        valid_out,   // result is valid this cycle

    // Result
    output logic [63:0] result
);

  // -------------------------------------------------------------------------
  // STUB — replace this block with a real multiplier/divider
  // -------------------------------------------------------------------------
  assign ready_out = 1'b1;
  assign valid_out = valid_in & en;
  assign result    = '0;

  // Suppress unused-signal warnings during stub phase
  logic _unused;
  assign _unused = clk & rst_n & (|op) & (|operand_a) & (|operand_b);

endmodule

`endif // MUL_DIV_SV
