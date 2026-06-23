
// =============================================================================
// hazard_unit.sv — Pipeline hazard detection and control
//
// Detects three hazard classes:
//   1. Load-use hazard  : EX stage is a load and ID stage reads same register
//                         → stall IF+ID for 1 cycle, insert bubble into EX
//   2. Memory stall     : MEM stage waiting for ACK (multi-cycle memory)
//                         → stall IF+ID+EX+MEM, no flush
//   3. Branch/jump flush: EX resolves taken branch or jump
//                         → flush IF and ID (2 instructions fetched wrongly)
// =============================================================================

`ifndef HAZARD_UNIT_SV
`define HAZARD_UNIT_SV

`timescale 1ns/1ps


module hazard_unit (
    // Pipeline register validity
    input  logic        id_ex_valid,
    input  logic        ex_mem_valid,

    // Decoded instruction info from ID stage
    input  logic [4:0]  id_rs1,
    input  logic [4:0]  id_rs2,

    // EX stage info
    input  logic [4:0]  ex_rd,
    input  logic        ex_mem_read,    // EX stage instruction is a load

    // MEM stage info
    input  logic [4:0]  mem_rd,

    // FP flag (uses separate register file — no integer hazard)
    input  logic        is_fp,

    // Memory stall (from mem_stage)
    input  logic        mem_stall,

    // Branch/jump signals (from ex_stage)
    input  logic        branch_taken,
    input  logic        is_jal,
    input  logic        is_jalr,

    // Output pipeline controls
    output logic        if_stall,   // hold IF stage (hold PC, hold IF/ID reg)
    output logic        id_stall,   // hold ID stage (hold ID/EX reg)
    output logic        ex_stall,   // hold EX stage
    output logic        mem_stall_o,// hold MEM stage (pass-through of mem_stall)
    output logic        if_flush,   // flush IF/ID register (insert NOP)
    output logic        id_flush    // flush ID/EX register (insert NOP)
);

 
  // Load-use hazard detection
  // If EX stage is a load AND its destination matches a source register
  // being read in ID stage → must stall 1 cycle
  logic load_use_hazard;

  always_comb begin
    load_use_hazard = 1'b0;
    if (id_ex_valid && ex_mem_read && !is_fp) begin
      if ((ex_rd != 5'd0) && ((ex_rd == id_rs1) || (ex_rd == id_rs2)))
        load_use_hazard = 1'b1;
    end
  end

 
  // Branch/jump flush
  // When a branch is taken or JAL/JALR executes, 2 wrong instructions are
  // already in IF and ID stages → flush both
  logic control_hazard;
  assign control_hazard = branch_taken || is_jal || is_jalr;

 
  // Output control signals
  //
  // Priority (highest first):
  //   1. mem_stall  — entire pipeline frozen
  //   2. load_use   — stall IF+ID, bubble into EX
  //   3. control    — flush IF+ID
  always_comb begin
    // Defaults
    if_stall    = 1'b0;
    id_stall    = 1'b0;
    ex_stall    = 1'b0;
    mem_stall_o = 1'b0;
    if_flush    = 1'b0;
    id_flush    = 1'b0;

    if (mem_stall) begin
      // Freeze entire pipeline until memory responds
      if_stall    = 1'b1;
      id_stall    = 1'b1;
      ex_stall    = 1'b1;
      mem_stall_o = 1'b1;
    end else if (load_use_hazard) begin
      // Stall IF+ID, inject bubble into EX (id_flush kills the ID/EX register)
      if_stall = 1'b1;
      id_stall = 1'b1;
      id_flush = 1'b1;
    end else if (control_hazard) begin
      // Flush the two wrongly-fetched instructions
      if_flush = 1'b1;
      id_flush = 1'b1;
    end
  end

endmodule

`endif // HAZARD_UNIT_SV
