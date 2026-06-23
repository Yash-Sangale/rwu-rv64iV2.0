`timescale 1ns / 1ps

`ifndef TYPES_PKG_H
`define TYPES_PKG_H

package types_pkg;

  import isa_pkg::*;

  typedef struct packed {
    opcode_t                    opcode;
    logic [REG_ADDRESS_LEN-1:0] rd;
    logic [REG_ADDRESS_LEN-1:0] rs1;
    logic [REG_ADDRESS_LEN-1:0] rs2;
    logic [2:0]                 funct3;
    logic [6:0]                 funct7;
    logic [XLEN-1:0]            imm;
    instruction_t               instruction;
    logic                       alu_src;
    logic                       mem_read;
    logic                       mem_write;
    logic                       reg_write;
    logic                       branch;
    logic                       jal;
    logic                       jalr;
    // FP control signals
    logic                       is_fp;
    logic                       fp_load;    // FLD/FLW — reads memory → fp regfile
    logic                       fp_store;   // FSD/FSW — rs2 from fp regfile
    logic [2:0]                 fp_rm;
    logic [4:0]                 fp_funct5;
    logic                       fp_cvt_toint;
    logic                       fp_cvt_word;
    logic                       fp_cvt_signed;
    logic [1:0]                 fp_fmt;     // FP_FMT_S or FP_FMT_D
    logic [1:0]                 fp_sgn_op;  // 00=FSGNJ 01=FSGNJN 10=FSGNJX
    logic                       fp_min_sel; // 0=FMIN 1=FMAX
  } decoded_instr_t;

  typedef struct packed {
    logic [XLEN-1:0] pc;
    logic [ILEN-1:0] instr;
    logic            valid;
  } if_id_reg_t;

  typedef struct packed {
    decoded_instr_t  dec;
    logic [XLEN-1:0] pc;
    logic [XLEN-1:0] rs1_val;
    logic [XLEN-1:0] rs2_val;
    logic [FLEN-1:0] fp_rs1_val;  // FP register read values
    logic [FLEN-1:0] fp_rs2_val;
    logic            valid;
  } id_ex_reg_t;

  typedef struct packed {
    decoded_instr_t  dec;
    logic [XLEN-1:0] alu_fpu_result;
    logic            fp_to_int;
    logic [4:0]      fp_fflags;
    logic [XLEN-1:0] rs2_val;
    logic [FLEN-1:0] fp_rs2_val;  // needed for FSD — fp register file source
    logic            branch_taken;
    logic [XLEN-1:0] branch_target;
    logic            addr_misaligned;
    logic            valid;
  } ex_mem_reg_t;

  typedef struct packed {
    decoded_instr_t  dec;
    logic [XLEN-1:0] alu_fpu_result;
    logic            fp_to_int;
    logic [4:0]      fp_fflags;
    logic            addr_misaligned;
    logic [XLEN-1:0] mem_rdata;
    logic [XLEN-1:0] wb_data;
    logic            valid;
  } mem_wb_reg_t;

endpackage

`endif // TYPES_PKG_H
