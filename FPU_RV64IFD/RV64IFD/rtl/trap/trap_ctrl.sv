// =============================================================================
// trap_ctrl.sv — Trap and interrupt controller
//
// Ported and adapted from reference design (asCPUx.sv) trap logic.
//
// Detects three trap classes in priority order:
//   1. Illegal instruction  (mcause = 2)
//   2. Address misalignment (mcause = 0/4/6 depending on access type)
//   3. External interrupt   (mcause = 0x8000_0000_0000_000B)
//
// RISC-V architectural model (from reference design commentary):
//   "Interrupt is Master, Pipeline is Slave"
//   Trap is taken at instruction-commit boundary, never mid-instruction.
//
// For the pipelined core, "commit boundary" = WB stage with valid instruction.
// For the no-pipeline core, it is the exec_phase of each instruction.
//
// Outputs:
//   trap_taken   — pulse: redirect PC to mtvec this cycle
//   trap_cause   — mcause value to write
//   trap_pc      — PC to save in mepc (PC of faulting instr, or PC+4 for IRQ)
//   mret_taken   — pulse: MRET instruction committed
// =============================================================================
`ifndef TRAP_CTRL_H
`define TRAP_CTRL_H 

`timescale 1ns / 1ps

`include "isa_pkg.sv"
`include "types_pkg.sv"

module trap_ctrl (
    input logic clk,
    input logic rst_n,

    //  Instruction info at commit (WB stage / exec phase) 
    input logic            instr_commit,           // instruction is committing this cycle
    input logic [XLEN-1:0] commit_pc,              // PC of committing instruction
    input logic [XLEN-1:0] commit_pc_plus4,        // commit_pc + 4
    input logic [     6:0] commit_opcode,          // instr[6:0]
    input logic [     2:0] commit_funct3,          // instr[14:12]
    // not needed 
    // input logic [XLEN-1:0] commit_alu_result,      // ALU result (load/store address)
    input logic            commit_branch_taken,    // branch/jump taken flag
    input logic [XLEN-1:0] commit_branch_target,
    input logic            commit_addr_misaligned,

    //  Decoder flags 
    input logic illegal_instr,  // decoder flagged illegal
    input logic is_mret,        // MRET instruction

    //  CSR status 
    input logic irq_pending,  // from csr_regfile

    //  Outputs to CSR and PC redirect 
    output logic            trap_taken,  // pulse → CSR save + PC redirect
    output logic [XLEN-1:0] trap_cause,  // mcause value
    output logic [XLEN-1:0] trap_pc,     // mepc value
    output logic            mret_taken   // pulse → MRET redirect
);

  import isa_pkg::*;

  //  Misalignment detection 
  logic trap_misaligned;
  logic is_load, is_store, is_branch_jump;

  assign is_load = (commit_opcode == OP_LOAD);
  assign is_store = (commit_opcode == OP_STORE);
  assign is_branch_jump = (commit_opcode == OP_BRANCH) ||
                          (commit_opcode == OP_JAL) ||
                          (commit_opcode == OP_JALR);

  always_comb begin
    trap_misaligned = 1'b0;

    if (instr_commit) begin
      // Load/Store misalignment (check effective address alignment vs width)
      if (is_load || is_store) begin
        trap_misaligned = commit_addr_misaligned;
      end
      // Branch/Jump target misalignment
      if (is_branch_jump && commit_branch_taken) begin
        if (commit_branch_target[1:0] != 2'b00) trap_misaligned = 1'b1;
      end
    end
  end

  //  Trap cause encoding 
  // Priority: illegal > misaligned > IRQ
  always_comb begin
    trap_cause = '0;
    if (illegal_instr) trap_cause = 64'd2;  // Illegal instruction
    else if (trap_misaligned) begin
      if (is_load) trap_cause = 64'd4;  // Load address misaligned
      else if (is_store) trap_cause = 64'd6;  // Store address misaligned
      else trap_cause = 64'd0;  // Instruction address misaligned
    end else if (irq_pending) trap_cause = {1'b1, 63'd11};  // Machine external interrupt
  end

  //  trap_pc: for exceptions save current PC; for IRQ save PC+4 (resume after) 
  always_comb begin
    if (illegal_instr || trap_misaligned) trap_pc = commit_pc;
    else trap_pc = commit_pc_plus4;
  end

  //  trap_taken: registered, cleared next cycle 
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) trap_taken <= 1'b0;
    else begin
      trap_taken <= 1'b0;  // default: clear
      if (instr_commit && !is_mret) begin
        if (illegal_instr || trap_misaligned || irq_pending) trap_taken <= 1'b1;
      end
    end
  end

  //  mret_taken: MRET commits 
  assign mret_taken = instr_commit && is_mret;

endmodule

`endif  // TRAP_CTRL_H
