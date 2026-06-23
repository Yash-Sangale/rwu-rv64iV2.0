`timescale 1ns / 1ps

`ifndef ISA_PKG_H
`define ISA_PKG_H

package isa_pkg;

  parameter int unsigned XLEN          = 64;
  parameter int unsigned FLEN          = 64;
  parameter int unsigned ILEN          = 32;
  parameter int unsigned REG_COUNT     = 32;
  parameter int unsigned REG_ADDRESS_LEN = 5;

   typedef enum logic {
    FP_FMT_S = 1'b0,
    FP_FMT_D = 1'b1
  } fp_fmt_t;

  // Opcode map [instr[6:0]]
  typedef enum logic [6:0] {
    OP_LOAD   = 7'b000_0011,
    OP_LOAD_FP= 7'b000_0111,  // FLW / FLD
    OP_STORE  = 7'b010_0011,
    OP_STORE_FP=7'b010_0111,  // FSW / FSD
    OP_BRANCH = 7'b110_0011,
    OP_JAL    = 7'b110_1111,
    OP_JALR   = 7'b110_0111,
    OP_LUI    = 7'b011_0111,
    OP_AUIPC  = 7'b001_0111,
    OP_IMM    = 7'b001_0011,
    OP_REG    = 7'b011_0011,
    OP_IMM32  = 7'b001_1011,
    OP_REG32  = 7'b011_1011,
    OP_SYSTEM = 7'b111_0011,
    OP_FENCE  = 7'b000_1111,
    OP_FP     = 7'b101_0011,
    OP_AMO    = 7'b010_1111
  } opcode_t;


  typedef enum logic [5:0] {
    // Base integer
    INST_ADD   = 6'd0,
    INST_SUB   = 6'd1,
    INST_AND   = 6'd2,
    INST_OR    = 6'd3,
    INST_XOR   = 6'd4,
    INST_SLL   = 6'd5,
    INST_SRL   = 6'd6,
    INST_SRA   = 6'd7,
    INST_SLT   = 6'd8,
    INST_SLTU  = 6'd9,
    INST_LUI   = 6'd10,
    // RV64I word ops
    INST_ADDW  = 6'd11,
    INST_SUBW  = 6'd12,
    INST_SLLW  = 6'd13,
    INST_SRLW  = 6'd14,
    INST_SRAW  = 6'd15,
    // RV64M
    INST_MUL   = 6'd16,
    INST_MULH  = 6'd17,
    INST_DIV   = 6'd18,
    INST_DIVU  = 6'd19,
    INST_REM   = 6'd20,
    INST_REMU  = 6'd21,
    // RV64F/D arithmetic (routed to FPU)
    INST_FADD  = 6'd22,
    INST_FSUB  = 6'd23,
    INST_FMUL  = 6'd24,
    INST_FDIV  = 6'd25,
    INST_FSQRT = 6'd26,
    INST_FCMP  = 6'd27,
    INST_FCVT  = 6'd28,
    // Phase 2: sign-injection, min/max, move, classify
    INST_FSGNJ  = 6'd29,
    INST_FMINMAX= 6'd30,
    INST_FMVXW  = 6'd31,  // FMV.X.W  (int ← fp bits, single)
    INST_FMVWX  = 6'd32,  // FMV.W.X  (fp  ← int bits, single)
    INST_FMVXD  = 6'd33,  // FMV.X.D  (int ← fp bits, double)
    INST_FMVDX  = 6'd34,  // FMV.D.X  (fp  ← int bits, double)
    INST_FCLASS = 6'd35,
    // FLD/FSD (decode-only; memory access handled by existing load/store path)
    INST_FLD   = 6'd36,
    INST_FSD   = 6'd37,
    INST_FLW   = 6'd38,
    INST_FSW   = 6'd39,
    // Phase 4: float↔float precision conversion
    INST_FCVT_SD = 6'd40,  // FCVT.S.D
    INST_FCVT_DS = 6'd41,  // FCVT.D.S
    // NOP / pipeline stall
    INST_NOP   = 6'd63
  } instruction_t;

endpackage

`endif // ISA_PKG_H
