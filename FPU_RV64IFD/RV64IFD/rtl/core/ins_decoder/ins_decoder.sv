// Instruction decoder — RV64IMFD
// All FP instructions (OP_FP, OP_LOAD_FP, OP_STORE_FP) set is_fp=1.
// fp_fmt selects single (FP_FMT_S) vs double (FP_FMT_D) for each operation.
// @Note fp_rm == 3'b111 means "use CSR.frm" — flagged here, substituted in EX.

`timescale 1ns / 1ps

`ifndef INS_DECODER_SV
`define INS_DECODER_SV 

`include "types_pkg.sv"
`include "isa_pkg.sv"

import isa_pkg::*;
import types_pkg::*;


module ins_decoder (
    input  logic           [ILEN-1:0] instr,
    output decoded_instr_t            dec,
    output logic                      illegal
);

  logic [6:0] opcode_raw;
  logic [4:0] rd, rs1, rs2;
  logic [2:0] funct3;
  logic [6:0] funct7;
  logic [4:0] fp_funct5;
  logic [1:0] fp_fmt_raw;  // instr[26:25]

  assign opcode_raw = instr[6:0];
  assign rd         = instr[11:7];
  assign funct3     = instr[14:12];
  assign rs1        = instr[19:15];
  assign rs2        = instr[24:20];
  assign funct7     = instr[31:25];
  assign fp_funct5  = funct7[6:2];  // instr[31:27]
  assign fp_fmt_raw = instr[26:25];  // fmt field

  logic [XLEN-1:0] imm_i, imm_s, imm_b, imm_u, imm_j;

  assign imm_i = {{52{instr[31]}}, instr[31:20]};
  assign imm_s = {{52{instr[31]}}, instr[31:25], instr[11:7]};
  assign imm_b = {{51{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
  assign imm_u = {{32{instr[31]}}, instr[31:12], 12'b0};
  assign imm_j = {{43{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};

  always_comb begin
    dec.opcode        = opcode_t'(opcode_raw);
    dec.rd            = rd;
    dec.rs1           = rs1;
    dec.rs2           = rs2;
    dec.funct3        = funct3;
    dec.funct7        = funct7;
    dec.imm           = '0;
    dec.instruction   = INST_NOP;
    dec.alu_src       = 1'b0;
    dec.mem_read      = 1'b0;
    dec.mem_write     = 1'b0;
    dec.reg_write     = 1'b0;
    dec.branch        = 1'b0;
    dec.jal           = 1'b0;
    dec.jalr          = 1'b0;
    dec.is_fp         = 1'b0;
    dec.fp_load       = 1'b0;
    dec.fp_store      = 1'b0;
    dec.fp_rm         = '0;
    dec.fp_funct5     = '0;
    dec.fp_cvt_toint  = 1'b0;
    dec.fp_cvt_word   = 1'b0;
    dec.fp_cvt_signed = 1'b0;
    dec.fp_fmt        = FP_FMT_D;
    dec.fp_sgn_op     = 2'b00;
    dec.fp_min_sel    = 1'b0;
    illegal           = 1'b0;

    unique case (opcode_t'(opcode_raw))

      OP_REG: begin
        dec.reg_write = 1'b1;
        unique case ({
          funct7, funct3
        })
          {7'b000_0000, 3'b000} : dec.instruction = INST_ADD;
          {7'b010_0000, 3'b000} : dec.instruction = INST_SUB;
          {7'b000_0000, 3'b001} : dec.instruction = INST_SLL;
          {7'b000_0000, 3'b010} : dec.instruction = INST_SLT;
          {7'b000_0000, 3'b011} : dec.instruction = INST_SLTU;
          {7'b000_0000, 3'b100} : dec.instruction = INST_XOR;
          {7'b000_0000, 3'b101} : dec.instruction = INST_SRL;
          {7'b010_0000, 3'b101} : dec.instruction = INST_SRA;
          {7'b000_0000, 3'b110} : dec.instruction = INST_OR;
          {7'b000_0000, 3'b111} : dec.instruction = INST_AND;
          // RV64M
          {7'b000_0001, 3'b000} : dec.instruction = INST_MUL;
          {7'b000_0001, 3'b001} : dec.instruction = INST_MULH;
          {7'b000_0001, 3'b100} : dec.instruction = INST_DIV;
          {7'b000_0001, 3'b101} : dec.instruction = INST_DIVU;
          {7'b000_0001, 3'b110} : dec.instruction = INST_REM;
          {7'b000_0001, 3'b111} : dec.instruction = INST_REMU;
          default: illegal = 1'b1;
        endcase
      end

      OP_IMM: begin
        dec.reg_write = 1'b1;
        dec.alu_src   = 1'b1;
        dec.imm       = imm_i;
        unique case (funct3)
          3'b000:  dec.instruction = INST_ADD;
          3'b010:  dec.instruction = INST_SLT;
          3'b011:  dec.instruction = INST_SLTU;
          3'b100:  dec.instruction = INST_XOR;
          3'b110:  dec.instruction = INST_OR;
          3'b111:  dec.instruction = INST_AND;
          3'b001: begin
            dec.instruction = INST_SLL;
            dec.imm = {58'b0, instr[25:20]};
          end
          3'b101: begin
            dec.instruction = funct7[5] ? INST_SRA : INST_SRL;
            dec.imm = {58'b0, instr[25:20]};
          end
          default: illegal = 1'b1;
        endcase
      end

      OP_REG32: begin
        dec.reg_write = 1'b1;
        unique case ({
          funct7, funct3
        })
          {7'b000_0000, 3'b000} : dec.instruction = INST_ADDW;
          {7'b010_0000, 3'b000} : dec.instruction = INST_SUBW;
          {7'b000_0000, 3'b001} : dec.instruction = INST_SLLW;
          {7'b000_0000, 3'b101} : dec.instruction = INST_SRLW;
          {7'b010_0000, 3'b101} : dec.instruction = INST_SRAW;
          default: illegal = 1'b1;
        endcase
      end

      OP_IMM32: begin
        dec.reg_write = 1'b1;
        dec.alu_src   = 1'b1;
        dec.imm       = imm_i;
        unique case (funct3)
          3'b000:  dec.instruction = INST_ADDW;
          3'b001: begin
            dec.instruction = INST_SLLW;
            dec.imm = {59'b0, instr[24:20]};
          end
          3'b101: begin
            dec.instruction = funct7[5] ? INST_SRAW : INST_SRLW;
            dec.imm = {59'b0, instr[24:20]};
          end
          default: illegal = 1'b1;
        endcase
      end

      OP_LOAD: begin
        dec.reg_write   = 1'b1;
        dec.mem_read    = 1'b1;
        dec.alu_src     = 1'b1;
        dec.instruction = INST_ADD;
        dec.imm         = imm_i;
      end

      OP_STORE: begin
        dec.mem_write   = 1'b1;
        dec.alu_src     = 1'b1;
        dec.instruction = INST_ADD;
        dec.imm         = imm_s;
      end

      OP_BRANCH: begin
        dec.branch = 1'b1;
        dec.imm    = imm_b;
        unique case (funct3)
          3'b000, 3'b001, 3'b100, 3'b101, 3'b110, 3'b111: dec.instruction = INST_SUB;
          default: illegal = 1'b1;
        endcase
      end

      OP_JAL: begin
        dec.jal       = 1'b1;
        dec.reg_write = 1'b1;
        dec.imm       = imm_j;
      end

      OP_JALR: begin
        dec.jalr        = 1'b1;
        dec.reg_write   = 1'b1;
        dec.alu_src     = 1'b1;
        dec.instruction = INST_ADD;
        dec.imm         = imm_i;
      end

      OP_LUI: begin
        dec.reg_write   = 1'b1;
        dec.instruction = INST_LUI;
        dec.alu_src     = 1'b1;
        dec.imm         = imm_u;
      end

      OP_AUIPC: begin
        dec.reg_write   = 1'b1;
        dec.instruction = INST_ADD;
        dec.alu_src     = 1'b1;
        dec.imm         = imm_u;
      end

      OP_SYSTEM: begin
        // CSR and trap instructions handled by csr_regfile / trap_ctrl
        // [Fix-1] All OP_SYSTEM encodings are architecturally valid.
        // funct3 != 000: CSR instructions — reg_write enables rd writeback
        //   of CSR read value via result mux (OP_SYSTEM → csr_rdata).
        // funct3 == 000: MRET / ECALL / EBREAK — no reg write, never illegal.
        //   @Note ECALL/EBREAK trigger traps through trap_ctrl, not the
        //   illegal path; they are @Todo for full exception support.
        // illegal stays 0 — all OP_SYSTEM sub-encodings are defined by spec
        // @Todo: ECALL / EBREAK
      end

      // FLD / FLW — load into FP register file
      OP_LOAD_FP: begin
        dec.is_fp       = 1'b1;
        dec.fp_load     = 1'b1;
        dec.mem_read    = 1'b1;
        dec.reg_write   = 1'b1;  // write to fp regfile (wb_stage checks fp_load)
        dec.alu_src     = 1'b1;
        dec.instruction = INST_ADD;
        dec.imm         = imm_i;
        dec.fp_fmt      = fp_fmt_t'(fp_fmt_raw);
        unique case (funct3)
          3'b010:  dec.instruction = INST_FLW;
          3'b011:  dec.instruction = INST_FLD;
          default: illegal = 1'b1;
        endcase
      end

      // FSD / FSW — store from FP register file
      OP_STORE_FP: begin
        dec.is_fp       = 1'b1;
        dec.fp_store    = 1'b1;
        dec.mem_write   = 1'b1;
        dec.alu_src     = 1'b1;
        dec.instruction = INST_ADD;
        dec.imm         = imm_s;
        dec.fp_fmt      = fp_fmt_t'(fp_fmt_raw);
        unique case (funct3)
          3'b010:  dec.instruction = INST_FSW;
          3'b011:  dec.instruction = INST_FSD;
          default: illegal = 1'b1;
        endcase
      end

      OP_FP: begin
        dec.is_fp     = 1'b1;
        dec.reg_write = 1'b1;
        dec.fp_funct5 = fp_funct5;
        dec.fp_rm     = funct3;  // @Note fp_rm==3'b111 → use CSR.frm (EX resolves)
        dec.fp_fmt    = fp_fmt_t'(fp_fmt_raw);

        unique case (fp_funct5)

          // Arithmetic — fmt distinguishes S vs D
          5'b00000: dec.instruction = INST_FADD;
          5'b00001: dec.instruction = INST_FSUB;
          5'b00010: dec.instruction = INST_FMUL;
          5'b00011: dec.instruction = INST_FDIV;

          5'b01011: begin  // FSQRT — rs2 must be 0 per spec
            dec.instruction = INST_FSQRT;
            if (rs2 != 5'b00000) illegal = 1'b1;
          end

          5'b00100: begin  // FSGNJ.*/FSGNJN.*/FSGNJX.*
            dec.instruction = INST_FSGNJ;
            unique case (funct3)
              3'b000:  dec.fp_sgn_op = 2'b00;  // FSGNJ
              3'b001:  dec.fp_sgn_op = 2'b01;  // FSGNJN
              3'b010:  dec.fp_sgn_op = 2'b10;  // FSGNJX
              default: illegal = 1'b1;
            endcase
          end

          5'b00101: begin  // FMIN / FMAX
            dec.instruction = INST_FMINMAX;
            unique case (funct3)
              3'b000:  dec.fp_min_sel = 1'b0;  // FMIN
              3'b001:  dec.fp_min_sel = 1'b1;  // FMAX
              default: illegal = 1'b1;
            endcase
          end

          5'b10100: begin  // FCMP: FEQ / FLT / FLE
            dec.instruction = INST_FCMP;
            // fpu_ctrl reads fp_rm for cmp_op encoding
          end

          5'b11000: begin  // FCVT float→int (FCVT.W.S, FCVT.WU.S, FCVT.L.S, FCVT.LU.S / D)
            dec.instruction  = INST_FCVT;
            dec.fp_cvt_toint = 1'b1;
            unique case (rs2)
              5'b00000: begin
                dec.fp_cvt_word   = 1'b1;
                dec.fp_cvt_signed = 1'b1;
              end
              5'b00001: begin
                dec.fp_cvt_word   = 1'b1;
                dec.fp_cvt_signed = 1'b0;
              end
              5'b00010: begin
                dec.fp_cvt_word   = 1'b0;
                dec.fp_cvt_signed = 1'b1;
              end
              5'b00011: begin
                dec.fp_cvt_word   = 1'b0;
                dec.fp_cvt_signed = 1'b0;
              end
              default: illegal = 1'b1;
            endcase
          end

          5'b11010: begin  // FCVT int→float (FCVT.S.W, FCVT.D.W, etc.)
            dec.instruction  = INST_FCVT;
            dec.fp_cvt_toint = 1'b0;
            unique case (rs2)
              5'b00000: begin
                dec.fp_cvt_word   = 1'b1;
                dec.fp_cvt_signed = 1'b1;
              end
              5'b00001: begin
                dec.fp_cvt_word   = 1'b1;
                dec.fp_cvt_signed = 1'b0;
              end
              5'b00010: begin
                dec.fp_cvt_word   = 1'b0;
                dec.fp_cvt_signed = 1'b1;
              end
              5'b00011: begin
                dec.fp_cvt_word   = 1'b0;
                dec.fp_cvt_signed = 1'b0;
              end
              default: illegal = 1'b1;
            endcase
          end

          5'b01000: begin  // FCVT.S.D / FCVT.D.S — fmt conversion
            unique case (rs2)
              5'b00000: dec.instruction = INST_FCVT_DS;  // FCVT.D.S
              5'b00001: dec.instruction = INST_FCVT_SD;  // FCVT.S.D
              default:  illegal = 1'b1;
            endcase
          end

          5'b11100: begin
            dec.fp_cvt_toint = 1'b1;  // result → integer regfile
            unique case ({
              fp_fmt_raw, funct3
            })
              {2'b00, 3'b000} : dec.instruction = INST_FMVXW;  // FMV.X.W
              {2'b01, 3'b000} : dec.instruction = INST_FMVXD;  // FMV.X.D
              {2'b00, 3'b001} : dec.instruction = INST_FCLASS;  // FCLASS.S
              {2'b01, 3'b001} : dec.instruction = INST_FCLASS;  // FCLASS.D
              default: illegal = 1'b1;
            endcase
          end

          5'b11110: begin
            unique case ({
              fp_fmt_raw, funct3
            })
              {2'b00, 3'b000} : dec.instruction = INST_FMVWX;  // FMV.W.X
              {2'b01, 3'b000} : dec.instruction = INST_FMVDX;  // FMV.D.X
              default: illegal = 1'b1;
            endcase
          end

          default: illegal = 1'b1;
        endcase
      end

      default: illegal = 1'b1;

    endcase
  end

endmodule

`endif  // INS_DECODER_SV
