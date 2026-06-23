`timescale 1ns/1ps

`ifndef EX_STAGE_SV
`define EX_STAGE_SV

`include "isa_pkg.sv"
`include "types_pkg.sv"
`include "alu_top.sv"
`include "fpu_top.sv"

import isa_pkg::*;
import types_pkg::*;

// EX stage — ALU + FPU dispatch.
//
// FLD/FLW: is_fp=1, fp_load=1 — address computed by integer ALU (rs1+imm),
//   result goes to mem_stage as a normal load, wb_stage routes to fp regfile.
// FSD/FSW: is_fp=1, fp_store=1 — address from integer ALU, store data from
//   fp_rs2_val (passed through to ex_mem.fp_rs2_val for mem_stage to use).
// FMV.*: is_fp=1, mv path — int_operand = rs1_val (integer source for FMV.*.X).
module ex_stage (
    input  logic clk,
    input  logic rst_n,

    input  id_ex_reg_t  id_ex,
    output ex_mem_reg_t ex_mem_next
);

  // CSR.frm substitution: if fp_rm==3'b111 decoder flagged "use CSR.frm".
  // @Todo: wire actual CSR.frm here when fcsr is implemented.
  // For now, default to RNE (3'b000) when fp_rm==3'b111.
  logic [2:0] effective_rm;
  assign effective_rm = (id_ex.dec.fp_rm == 3'b111) ? 3'b000 : id_ex.dec.fp_rm;

  // Integer ALU operands
  logic [XLEN-1:0] op_a, op_b;
  assign op_a = id_ex.rs1_val;
  assign op_b = id_ex.dec.alu_src ? id_ex.dec.imm : id_ex.rs2_val;

  logic [XLEN-1:0] alu_result;
  logic zero, negative, overflow, carry;
  logic flag_eq, flag_lt_s, flag_lt_u;

  alu_top u_alu (
      .inst            (id_ex.dec.instruction),
      .operand_a       (op_a),
      .operand_b       (op_b),
      .result          (alu_result),
      .zero            (zero), .negative(negative),
      .overflow        (overflow), .carry(carry),
      .flag_eq         (flag_eq), .flag_lt_s(flag_lt_s), .flag_lt_u(flag_lt_u),
      .clk             (clk), .rst_n(rst_n),
      .muldiv_valid_in (1'b0),
      .muldiv_ready    (), .muldiv_valid_out()
  );

  // FPU
  logic [FLEN-1:0] fpu_result;
  logic            fpu_to_int;
  logic [4:0]      fpu_fflags;

  fpu_top u_fpu (
      .clk          (clk), .rst_n(rst_n),
      .inst         (id_ex.dec.instruction),
      .fp_funct5    (id_ex.dec.fp_funct5),
      .fp_rm        (effective_rm),
      .fp_cvt_toint (id_ex.dec.fp_cvt_toint),
      .fp_cvt_word  (id_ex.dec.fp_cvt_word),
      .fp_cvt_signed(id_ex.dec.fp_cvt_signed),
      .fp_fmt       (id_ex.dec.fp_fmt),
      .fp_sgn_op    (id_ex.dec.fp_sgn_op),
      .fp_min_sel   (id_ex.dec.fp_min_sel),
      .operand_a    (id_ex.fp_rs1_val),   // FP register file source
      .operand_b    (id_ex.fp_rs2_val),
      .int_operand  (id_ex.rs1_val),      // integer rs1 for FMV.*.X
      .result       (fpu_result),
      .to_int       (fpu_to_int),
      .fflags       (fpu_fflags),
      .div_valid_in (1'b1),
      .div_ready    (), .div_valid_out()
  );

  // Result mux: FP load/store use integer ALU address; other FP use FPU result
  logic [XLEN-1:0] ex_result;
  assign ex_result = (id_ex.dec.is_fp && !id_ex.dec.fp_load && !id_ex.dec.fp_store)
                     ? fpu_result : alu_result;

  // Branch logic
  logic branch_taken;
  always_comb begin
    branch_taken = 1'b0;
    if (id_ex.dec.branch) begin
      unique case (id_ex.dec.funct3)
        3'b000: branch_taken = flag_eq;
        3'b001: branch_taken = !flag_eq;
        3'b100: branch_taken = flag_lt_s;
        3'b101: branch_taken = !flag_lt_s;
        3'b110: branch_taken = flag_lt_u;
        3'b111: branch_taken = !flag_lt_u;
        default: branch_taken = 1'b0;
      endcase
    end
  end

  logic [XLEN-1:0] branch_target;
  assign branch_target = id_ex.dec.jalr
      ? ((id_ex.rs1_val + id_ex.dec.imm) & ~{{XLEN-1{1'b0}}, 1'b1})
      : (id_ex.pc + id_ex.dec.imm);

  // Misalignment (for loads/stores and branch targets — fed to trap_ctrl via MEM)
  logic addr_misaligned;
  always_comb begin
    addr_misaligned = 1'b0;
    if (id_ex.dec.mem_read || id_ex.dec.mem_write) begin
      unique case (id_ex.dec.funct3)
        3'b001, 3'b101: addr_misaligned = alu_result[0];
        3'b010, 3'b110: addr_misaligned = |alu_result[1:0];
        3'b011:         addr_misaligned = |alu_result[2:0];
        default:        addr_misaligned = 1'b0;
      endcase
    end
    if ((id_ex.dec.branch && branch_taken) || id_ex.dec.jal || id_ex.dec.jalr)
      if (branch_target[1:0] != 2'b00) addr_misaligned = 1'b1;
  end

  always_comb begin
    ex_mem_next.dec            = id_ex.dec;
    ex_mem_next.alu_fpu_result = ex_result;
    ex_mem_next.fp_to_int      = fpu_to_int;
    ex_mem_next.fp_fflags      = fpu_fflags;
    ex_mem_next.rs2_val        = id_ex.rs2_val;
    ex_mem_next.fp_rs2_val     = id_ex.fp_rs2_val;  // FSD store data
    ex_mem_next.branch_taken   = branch_taken || id_ex.dec.jal || id_ex.dec.jalr;
    ex_mem_next.branch_target  = branch_target;
    ex_mem_next.addr_misaligned= addr_misaligned;
    ex_mem_next.valid          = id_ex.valid;
  end

endmodule

`endif
