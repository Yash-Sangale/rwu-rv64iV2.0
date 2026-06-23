`timescale 1ns/1ps

`ifndef COMPARATOR_SV
`define COMPARATOR_SV

// =============================================================================
// comparator.sv — Integer Comparator
//
// Produces the single-bit less-than result for SLT / SLTU instructions,
// and the full set of branch condition flags used by the core to evaluate
// BEQ / BNE / BLT / BGE / BLTU / BGEU.
//
// Purely combinational. Stateless.
//
// Two groups of outputs:
//
//   1. lt_result  — 64-bit value: 0x1 if A < B, else 0x0
//                   Written to rd by SLT / SLTU instructions.
//
//   2. Branch flags (eq, lt_s, lt_u) — used by core.sv to resolve branches.
//      The core combines these:
//        BEQ   → eq
//        BNE   → !eq
//        BLT   → lt_s
//        BGE   → !lt_s
//        BLTU  → lt_u
//        BGEU  → !lt_u
//
// Note on adder sharing:
//   Some implementations compute (A - B) and read the flags from the adder.
//   We keep this separate so the adder and comparator are independently
//   testable. The synthesiser will merge them into one subtractor if it
//   determines that is more efficient.
// =============================================================================

module comparator (
    input  logic [63:0]  operand_a,
    input  logic [63:0]  operand_b,
    input  logic         cmp_signed,    // 1 = signed compare, 0 = unsigned

    // SLT / SLTU result (to be written to rd)
    output logic [63:0]  lt_result,     // 1 if A < B per cmp_signed, else 0

    // Branch resolution flags (always computed, used selectively by core)
    output logic         flag_eq,       // A == B
    output logic         flag_lt_s,     // A <  B  (signed)
    output logic         flag_lt_u      // A <  B  (unsigned)
);

  // Equality
  assign flag_eq   = (operand_a == operand_b);

  // Signed less-than — $signed cast maps to a single comparator in synthesis
  assign flag_lt_s = ($signed(operand_a) < $signed(operand_b));

  // Unsigned less-than
  assign flag_lt_u = (operand_a < operand_b);

  // SLT / SLTU result: mux between signed and unsigned
  assign lt_result = cmp_signed ? {{63{1'b0}}, flag_lt_s}
                                 : {{63{1'b0}}, flag_lt_u};

endmodule

`endif // COMPARATOR_SV
