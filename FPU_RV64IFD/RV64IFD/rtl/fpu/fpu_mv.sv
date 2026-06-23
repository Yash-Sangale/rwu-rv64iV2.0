`timescale 1ns / 1ps

`ifndef FPU_MV_SV
`define FPU_MV_SV

`include "isa_pkg.sv"
import isa_pkg::*;

// fpu_mv.sv — FMV.X.W / FMV.X.D / FMV.W.X / FMV.D.X
//
// Pure bit-copy, no conversion. No rounding, no exception flags.
//
// FMV.X.W : integer rd ← sign_extend(fp_rs1[31:0])   (fp_fmt=S, fp_to_int=1)
// FMV.X.D : integer rd ← fp_rs1[63:0]                (fp_fmt=D, fp_to_int=1)
// FMV.W.X : fp rd ← NaN_box(int_rs1[31:0])           (fp_fmt=S)
// FMV.D.X : fp rd ← int_rs1[63:0]                    (fp_fmt=D)
//
// @Note NaN boxing: FMV.W.X writes integer [31:0] into fp register
//   with upper 32 bits set to all-ones per RV spec §11.3.
module fpu_mv (
    input  logic            en,
    input  logic [XLEN-1:0] int_src,   // source integer register (for FMV.W/D.X)
    input  logic [FLEN-1:0] fp_src,    // source fp register     (for FMV.X.W/D)
    input  instruction_t    inst,
    input  logic [1:0]      fp_fmt,
    output logic [XLEN-1:0] int_result, // to integer regfile (FMV.X.*)
    output logic [FLEN-1:0] fp_result,  // to fp regfile      (FMV.*.X)
    output logic            to_int      // 1 = write to integer regfile
);

  always_comb begin
    int_result = '0;
    fp_result  = '0;
    to_int     = 1'b0;

    if (en) begin
      unique case (inst)
        INST_FMVXW: begin   // FMV.X.W: sign-extend fp[31:0] → int rd
          to_int     = 1'b1;
          int_result = {{32{fp_src[31]}}, fp_src[31:0]};
        end
        INST_FMVXD: begin   // FMV.X.D: fp[63:0] → int rd
          to_int     = 1'b1;
          int_result = fp_src;
        end
        INST_FMVWX: begin   // FMV.W.X: NaN-box int[31:0] → fp rd
          fp_result = {32'hFFFF_FFFF, int_src[31:0]};
        end
        INST_FMVDX: begin   // FMV.D.X: int[63:0] → fp rd
          fp_result = int_src;
        end
        default: begin end
      endcase
    end
  end

endmodule

`endif // FPU_MV_SV
