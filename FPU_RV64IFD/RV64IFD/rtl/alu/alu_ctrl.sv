// =============================================================================
// alu_ctrl.sv — ALU Control Unit
//
// Single combinational block that decodes instruction_t into individual enable
// and select signals consumed by each functional unit.
//
// Nothing in this module does any arithmetic — it is pure decode logic.
// Every functional unit (adder, shifter, comparator, mul_div) takes only
// the signals it needs; they never inspect instruction_t directly.
//
// Adding a new operation:
//   1. Add the instruction_t entry in isa_pkg.sv
//   2. Add a new control signal here and set it in the case statement
//   3. Wire it into alu_top.sv
//
// Port naming convention:
//   adder_*    — signals to the adder inside alu_top
//   shift_*    — signals to shifter.sv
//   cmp_*      — signals to comparator.sv
//   muldiv_*   — signals to mul_div.sv  (reserved, not yet used)
//   res_sel    — selects which unit's output becomes alu_top result
// =============================================================================

`ifndef ALU_CTRL_SV
`define ALU_CTRL_SV

`timescale 1ns/1ps

`include "isa_pkg.sv"
import isa_pkg::*;

// Result source mux select — one-hot for safety
typedef enum logic [2:0] {
    SEL_ADDER   = 3'b000,   // ADD / SUB / ADDW / SUBW
    SEL_LOGIC   = 3'b001,   // AND / OR / XOR / LUI
    SEL_SHIFT   = 3'b010,   // SLL / SRL / SRA / SLLW / SRLW / SRAW
    SEL_COMPARE = 3'b011,   // SLT / SLTU
    SEL_MULDIV  = 3'b100,   // MUL / DIV / REM  (future)
    SEL_PASSA   = 3'b101    // NOP — pass operand_a through
} res_sel_t;

// Logic unit sub-select
typedef enum logic [1:0] {
    LOGIC_AND = 2'b00,
    LOGIC_OR  = 2'b01,
    LOGIC_XOR = 2'b10,
    LOGIC_LUI = 2'b11    // pass operand_b (upper immediate)
} logic_sel_t;

module alu_ctrl (
    input  instruction_t    inst,

    // --- Adder controls ---
    output logic       adder_en,      // 1 = adder result is needed
    output logic       adder_sub,     // 1 = subtract (A - B), 0 = add (A + B)
    output logic       adder_word,    // 1 = 32-bit word op (sign-extend result)

    // --- Logic unit controls ---
    output logic_sel_t logic_sel,     // which logic operation

    // --- Shifter controls ---
    output logic       shift_en,      // 1 = shifter result is needed
    output logic       shift_left,    // 1 = left shift, 0 = right shift
    output logic       shift_arith,   // 1 = arithmetic (SRA), 0 = logical (SRL)
    output logic       shift_word,    // 1 = 32-bit word op

    // --- Comparator controls ---
    output logic       cmp_en,        // 1 = comparator result is needed
    output logic       cmp_signed,    // 1 = signed compare (SLT), 0 = unsigned (SLTU)

    // --- Mul/div controls (reserved for RV64M) ---
    output logic       muldiv_en,     // 1 = mul/div unit result is needed
    output logic [2:0] muldiv_op,     // sub-operation select (MUL/MULH/DIV/etc.)

    // --- Result mux ---
    output res_sel_t   res_sel        // which unit drives the result bus
);

  always_comb begin
    // Safe defaults — all units disabled, result zeroed
    adder_en    = 1'b0;
    adder_sub   = 1'b0;
    adder_word  = 1'b0;
    logic_sel   = LOGIC_AND;
    shift_en    = 1'b0;
    shift_left  = 1'b0;
    shift_arith = 1'b0;
    shift_word  = 1'b0;
    cmp_en      = 1'b0;
    cmp_signed  = 1'b0;
    muldiv_en   = 1'b0;
    muldiv_op   = 3'b000;
    res_sel     = SEL_PASSA;

    unique case (inst)

      // ---------------------------------------------------------------
      // Adder group
      // ---------------------------------------------------------------
      INST_ADD: begin
        adder_en  = 1'b1;
        adder_sub = 1'b0;
        res_sel   = SEL_ADDER;
      end
      INST_SUB: begin
        adder_en  = 1'b1;
        adder_sub = 1'b1;
        res_sel   = SEL_ADDER;
      end
      INST_ADDW: begin
        adder_en   = 1'b1;
        adder_sub  = 1'b0;
        adder_word = 1'b1;
        res_sel    = SEL_ADDER;
      end
      INST_SUBW: begin
        adder_en   = 1'b1;
        adder_sub  = 1'b1;
        adder_word = 1'b1;
        res_sel    = SEL_ADDER;
      end

      // ---------------------------------------------------------------
      // Logic group
      // ---------------------------------------------------------------
      INST_AND: begin
        logic_sel = LOGIC_AND;
        res_sel   = SEL_LOGIC;
      end
      INST_OR: begin
        logic_sel = LOGIC_OR;
        res_sel   = SEL_LOGIC;
      end
      INST_XOR: begin
        logic_sel = LOGIC_XOR;
        res_sel   = SEL_LOGIC;
      end
      INST_LUI: begin
        logic_sel = LOGIC_LUI;
        res_sel   = SEL_LOGIC;
      end

      // ---------------------------------------------------------------
      // Shifter group
      // ---------------------------------------------------------------
      INST_SLL: begin
        shift_en   = 1'b1;
        shift_left = 1'b1;
        res_sel    = SEL_SHIFT;
      end
      INST_SRL: begin
        shift_en    = 1'b1;
        shift_left  = 1'b0;
        shift_arith = 1'b0;
        res_sel     = SEL_SHIFT;
      end
      INST_SRA: begin
        shift_en    = 1'b1;
        shift_left  = 1'b0;
        shift_arith = 1'b1;
        res_sel     = SEL_SHIFT;
      end
      INST_SLLW: begin
        shift_en   = 1'b1;
        shift_left = 1'b1;
        shift_word = 1'b1;
        res_sel    = SEL_SHIFT;
      end
      INST_SRLW: begin
        shift_en    = 1'b1;
        shift_left  = 1'b0;
        shift_arith = 1'b0;
        shift_word  = 1'b1;
        res_sel     = SEL_SHIFT;
      end
      INST_SRAW: begin
        shift_en    = 1'b1;
        shift_left  = 1'b0;
        shift_arith = 1'b1;
        shift_word  = 1'b1;
        res_sel     = SEL_SHIFT;
      end

      // ---------------------------------------------------------------
      // Comparator group
      // ---------------------------------------------------------------
      INST_SLT: begin
        cmp_en     = 1'b1;
        cmp_signed = 1'b1;
        res_sel    = SEL_COMPARE;
      end
      INST_SLTU: begin
        cmp_en     = 1'b1;
        cmp_signed = 1'b0;
        res_sel    = SEL_COMPARE;
      end

      // ---------------------------------------------------------------
      // NOP — pass operand_a through unchanged (pipeline stall)
      // ---------------------------------------------------------------
      INST_NOP: begin
        res_sel = SEL_PASSA;
      end

      // ---------------------------------------------------------------
      // Future: RV64M mul/div (uncomment when mul_div.sv is active)
      // INST_MUL:  begin muldiv_en=1; muldiv_op=3'd0; res_sel=SEL_MULDIV; end
      // INST_MULH: begin muldiv_en=1; muldiv_op=3'd1; res_sel=SEL_MULDIV; end
      // INST_DIV:  begin muldiv_en=1; muldiv_op=3'd2; res_sel=SEL_MULDIV; end
      // INST_DIVU: begin muldiv_en=1; muldiv_op=3'd3; res_sel=SEL_MULDIV; end
      // INST_REM:  begin muldiv_en=1; muldiv_op=3'd4; res_sel=SEL_MULDIV; end
      // INST_REMU: begin muldiv_en=1; muldiv_op=3'd5; res_sel=SEL_MULDIV; end
      // ---------------------------------------------------------------

      default: begin
        res_sel = SEL_PASSA;
      end

    endcase
  end

endmodule

`endif // ALU_CTRL_SV
