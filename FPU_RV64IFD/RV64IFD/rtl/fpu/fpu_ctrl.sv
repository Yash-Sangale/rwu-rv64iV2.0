`timescale 1ns / 1ps

`ifndef FPU_CTRL_SV
`define FPU_CTRL_SV

`include "isa_pkg.sv"
import isa_pkg::*;

// fpu_ctrl.sv — FPU control unit.
// Decodes instruction_t FP subset + auxiliary fields into per-unit enable/select.
// Extended for full RV64FD: sign-injection, min/max, move, classify, fmt conversion.

typedef enum logic [3:0] {
  FPU_SEL_ADDSUB  = 4'd0,
  FPU_SEL_MUL     = 4'd1,
  FPU_SEL_DIV     = 4'd2,
  FPU_SEL_SQRT    = 4'd3,
  FPU_SEL_CMP     = 4'd4,
  FPU_SEL_CVT     = 4'd5,
  FPU_SEL_SIGN    = 4'd6,
  FPU_SEL_MINMAX  = 4'd7,
  FPU_SEL_MV      = 4'd8,
  FPU_SEL_CLASS   = 4'd9,
  FPU_SEL_CVTFMT  = 4'd10,  // FCVT.S.D / FCVT.D.S
  FPU_SEL_PASS    = 4'd15
} fpu_res_sel_t;

module fpu_ctrl (
    input  instruction_t  inst,
    input  logic [4:0]    fp_funct5,
    input  logic [2:0]    fp_rm,
    // Per-unit enables
    output logic          addsub_en,
    output logic          addsub_sub,
    output logic          mul_en,
    output logic          div_en,
    output logic          sqrt_en,
    output logic          cmp_en,
    output logic [1:0]    cmp_op,
    output logic          cvt_en,
    output logic          sign_en,
    output logic          minmax_en,
    output logic          mv_en,
    output logic          class_en,
    output logic          cvtfmt_en,
    // Result mux
    output fpu_res_sel_t  res_sel
);

  always_comb begin
    addsub_en = 1'b0; addsub_sub = 1'b0;
    mul_en    = 1'b0; div_en     = 1'b0;
    sqrt_en   = 1'b0; cmp_en     = 1'b0;
    cmp_op    = 2'd0; cvt_en     = 1'b0;
    sign_en   = 1'b0; minmax_en  = 1'b0;
    mv_en     = 1'b0; class_en   = 1'b0;
    cvtfmt_en = 1'b0;
    res_sel   = FPU_SEL_PASS;

    unique case (inst)
      INST_FADD:  begin addsub_en = 1'b1; addsub_sub = 1'b0; res_sel = FPU_SEL_ADDSUB; end
      INST_FSUB:  begin addsub_en = 1'b1; addsub_sub = 1'b1; res_sel = FPU_SEL_ADDSUB; end
      INST_FMUL:  begin mul_en    = 1'b1;                     res_sel = FPU_SEL_MUL;    end
      INST_FDIV:  begin div_en    = 1'b1;                     res_sel = FPU_SEL_DIV;    end
      INST_FSQRT: begin sqrt_en   = 1'b1;                     res_sel = FPU_SEL_SQRT;   end

      INST_FCMP: begin
        cmp_en = 1'b1;
        unique case (fp_rm)
          3'b010:  cmp_op = 2'd0;  // FEQ
          3'b001:  cmp_op = 2'd1;  // FLT
          3'b000:  cmp_op = 2'd2;  // FLE
          default: cmp_op = 2'd0;
        endcase
        res_sel = FPU_SEL_CMP;
      end

      INST_FCVT:    begin cvt_en    = 1'b1; res_sel = FPU_SEL_CVT;    end
      INST_FSGNJ:   begin sign_en   = 1'b1; res_sel = FPU_SEL_SIGN;   end
      INST_FMINMAX: begin minmax_en = 1'b1; res_sel = FPU_SEL_MINMAX; end

      INST_FMVXW, INST_FMVXD,
      INST_FMVWX, INST_FMVDX:
                    begin mv_en     = 1'b1; res_sel = FPU_SEL_MV;     end

      INST_FCLASS:  begin class_en  = 1'b1; res_sel = FPU_SEL_CLASS;  end

      INST_FCVT_SD,
      INST_FCVT_DS: begin cvtfmt_en = 1'b1; res_sel = FPU_SEL_CVTFMT; end

      default: res_sel = FPU_SEL_PASS;
    endcase
  end

endmodule

`endif // FPU_CTRL_SV
