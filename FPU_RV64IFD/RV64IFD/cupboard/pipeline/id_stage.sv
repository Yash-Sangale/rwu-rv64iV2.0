`timescale 1ns / 1ps

`ifndef ID_STAGE_SV
`define ID_STAGE_SV

`include "isa_pkg.sv"
`include "types_pkg.sv"
`include "ins_decoder.sv"

import isa_pkg::*;
import types_pkg::*;

// ID stage — decode + register file read operand routing.
//
// Operand routing rules:
//   FP arithmetic (is_fp && !fp_load && !fp_store):
//     fp_rs1_val  ← fp regfile rs1
//     fp_rs2_val  ← fp regfile rs2
//     rs1_val     ← integer rs1  (kept for FMV.*.X integer source)
//     rs2_val     ← integer rs2
//
//   FLD / FLW (fp_load):
//     Address = integer rs1 + imm  → computed by integer ALU in EX
//     rs1_val ← integer rs1, rs2_val unused
//
//   FSD / FSW (fp_store):
//     Address  = integer rs1 + imm → integer ALU
//     Store data = fp rs2          → fp_rs2_val passed to MEM stage
//     rs1_val ← integer rs1
//     fp_rs2_val ← fp regfile rs2
//
//   Integer: rs1_val/rs2_val ← integer regfile, fp values zero
module id_stage (
    input  logic clk,
    input  logic rst_n,

    input  if_id_reg_t if_id,

    output logic [4:0] rs1_addr,
    output logic [4:0] rs2_addr,

    input  logic [XLEN-1:0] int_rs1_data,
    input  logic [XLEN-1:0] int_rs2_data,
    input  logic [FLEN-1:0] fp_rs1_data,
    input  logic [FLEN-1:0] fp_rs2_data,

    output id_ex_reg_t id_ex_next
);

  decoded_instr_t dec;
  logic           illegal;

  ins_decoder u_decoder (
      .instr  (if_id.instr),
      .dec    (dec),
      .illegal(illegal)
  );

  assign rs1_addr = dec.rs1;
  assign rs2_addr = dec.rs2;

  always_comb begin
    id_ex_next.dec       = dec;
    id_ex_next.pc        = if_id.pc;
    id_ex_next.valid     = if_id.valid && !illegal;

    // Default: integer sources
    id_ex_next.rs1_val    = int_rs1_data;
    id_ex_next.rs2_val    = int_rs2_data;
    id_ex_next.fp_rs1_val = '0;
    id_ex_next.fp_rs2_val = '0;

    if (dec.is_fp) begin
      if (dec.fp_load) begin
        // FLD/FLW: integer rs1 for address calc; no fp operand needed in EX
        id_ex_next.rs1_val    = int_rs1_data;
      end else if (dec.fp_store) begin
        // FSD/FSW: integer rs1 for address; fp rs2 is the store data
        id_ex_next.rs1_val    = int_rs1_data;
        id_ex_next.fp_rs2_val = fp_rs2_data;
      end else begin
        // All other FP: both operands from fp regfile
        // Keep rs1_val = integer rs1 for FMV.*.X (integer source)
        id_ex_next.fp_rs1_val = fp_rs1_data;
        id_ex_next.fp_rs2_val = fp_rs2_data;
      end
    end
  end

endmodule

`endif
