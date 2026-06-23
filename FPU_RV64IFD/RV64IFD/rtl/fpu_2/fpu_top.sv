`timescale 1ns / 1ps

/*********************************************************************************
 * File Name:    fpu_top.sv
 * Description:  The main motherboard of the FPU. It connects the controller, 
 *               the math blocks, and the normalizer together using multiplexers.
 *
 * Inputs:       clk, rst, rs1 (input 1), rs2 (input 2), op (operation code)
 * Outputs:      rd (final result), flags (error/status flags)
 *
 * Notes:        The math blocks dump their raw answers here, and this module 
 *               uses a Mux to route the right answer to the shared normalizer.
 *               If there's a special case (like a NaN), it bypasses the math entirely.
 *********************************************************************************/

module fpu_top(

    input logic                     clk,
    input logic                     rst,

    input fpu_pkg::fp64_t           rs1,    // input 1
    input fpu_pkg::fp64_t           rs2,    // input 2
    input fpu_pkg::fp64_t           rs3,    // input 3 (for fused ops)
    input fpu_pkg::fpu_op_t         op,     // received opcode    
    
    output fpu_pkg::fp64_t          rd_fp,      // result for floating point regs
    output logic [63:0]             rd_int,     // result for interger reg
    output fpu_pkg::fpu_fflags_t    flags,       // status flags
    
    output logic                    fpu_stalled // from division FSM
    
    );
    
import fpu_pkg::*;

// TODO: Use logic fo rFPU inputs, type cast to fpu64_t

// --- INTERNAL WIRES ---
logic           is_sub_wire;
fpu_res_sel_t   datapath_sel_wire;

logic           handle_special_wire;
fp64_t          special_result_wire;
fpu_fflags_t    special_flags_wire;

// Raw outputs from fpu_add_sub (Unpacked)
logic           adder_sign;
logic [10:0]    adder_exp;
logic [56:0]    adder_mant_raw;

// Raw outputs from fpu_mul
logic           mul_sign;
logic [10:0]    mul_exp;
logic [56:0]    mul_mant;

// Raw outputs from fpu_fma
logic           fma_sign;
logic [10:0]    fma_exp;
logic [56:0]    fma_mant;

// Raw outputs from fpu_div_sqrt
logic           div_sqrt_sign;
logic [10:0]    div_sqrt_exp;
logic [56:0]    div_sqrt_mant;
logic           div_busy;
logic           div_done;

// start pulse generated only if the operation is valid and not a special case
logic div_start_wire;
assign div_start_wire = (datapath_sel_wire == SEL_DIV_SQRT) && !handle_special_wire;

// Inputs to comparator
logic [9:0]     rs1_mask_wire;
logic [9:0]     rs2_mask_wire;
logic [9:0]     rs3_mask_wire;

// Outputs from comparator
logic [63:0]    cmp_res_int;
fp64_t          cmp_res_fp;
fpu_fflags_t    cmp_fflags;

// Inputs to the Normalizer
logic           math_sign_raw;
logic [10:0]    math_exp_raw;
logic [56:0]    math_mant_raw;

// Outputs from the Normalizer
logic           norm_sign;
logic [10:0]    norm_exp;
logic [51:0]    norm_mant;

// Inputs to rounding
logic norm_guard;
logic norm_round;
logic norm_sticky;

// Intermediate for rounding
fp64_t       rounded_result;
fpu_fflags_t rounded_flags;

fpu_ctrl ctrl_inst(
    
    .op(op),
    .rs1(rs1),
    .rs2(rs2),
    .rs3(rs3),

    .is_sub(is_sub_wire),
    .datapath_select(datapath_sel_wire),

    .handle_special(handle_special_wire),
    .special_result(special_result_wire),
    .special_flags(special_flags_wire),

    .rs1_mask_out(rs1_mask_wire),
    .rs2_mask_out(rs2_mask_wire),
    .rs3_mask_out(rs3_mask_wire)


);
    
fpu_add_sub adder_inst (

    .a(rs1), 
    .b(rs2), 
    .is_sub(is_sub_wire),      
    
    .sign(adder_sign),
    .exp_out(adder_exp),
    .mant_sum_out(adder_mant_raw)
);

fpu_mul multiplier_inst (
   .a(rs1), 
   .b(rs2),
   
   .sign_out(mul_sign), 
   .exp_out(mul_exp), 
   .mant_out(mul_mant)
);

fpu_fma fma_inst (
    .a(rs1),
    .b(rs2),
    .c(rs3),
    .op(op),

    .sign_out(fma_sign),
    .exp_out(fma_exp),
    .mant_out(fma_mant)
    
);

fpu_cmp cmp_inst (
    .rs1(rs1),
    .rs2(rs2),
    .op(op),
    .rs1_mask(rs1_mask_wire),
    .rs2_mask(rs2_mask_wire),

    .rd_int(cmp_res_int),
    .rd_fp(cmp_res_fp),
    .flags(cmp_fflags)
);

fpu_normalize norm_inst (
    .sign_in(math_sign_raw),
    .exp_in(math_exp_raw),
    .mant_in(math_mant_raw),
    
    .sign_out(norm_sign),
    .exp_out(norm_exp),
    .mant_out(norm_mant),

    .guard_out(norm_guard),
    .round_out(norm_round),
    .sticky_out(norm_sticky)
);


fpu_rounding rounding_inst (
    .sign(norm_sign),
    .exp_in(norm_exp),
    .mant_in(norm_mant),

    .guard(norm_guard), 
    .rnd(norm_round),
    .stky(norm_sticky),
    .rm(RM_RNE),        // HARDCODED FOR NOW
    
    .rd(rounded_result),            
    .flags(rounded_flags)
);


fpu_div_sqrt div_sqrt_inst (
    .clk(clk),
    .rst(rst),
    .start(div_start_wire),
    .busy(div_busy),
    .done(div_done),
    .a(rs1),
    .b(rs2),
    .op(op),
    .sign_out(div_sqrt_sign),
    .exp_out(div_sqrt_exp),
    .mant_out(div_sqrt_mant)
);

// This picks which raw results are directed towards normalization
always_comb begin
    case (datapath_sel_wire) // Signal from fpu_ctrl
        SEL_ADDER: begin
            math_sign_raw = adder_sign;
            math_exp_raw  = adder_exp;
            math_mant_raw = adder_mant_raw;        
        end
        
        SEL_MUL: begin
            math_sign_raw = mul_sign;
            math_exp_raw  = mul_exp;
            math_mant_raw = mul_mant;
        end
             
        SEL_FMA: begin
            math_sign_raw = fma_sign;
            math_exp_raw  = fma_exp;
            math_mant_raw = fma_mant;
        end

        SEL_DIV_SQRT: begin
            math_sign_raw = div_sqrt_sign;
            math_exp_raw  = div_sqrt_exp;
            math_mant_raw = div_sqrt_mant;
        end

        default: begin
            math_sign_raw = 1'b0;
            math_exp_raw  = '0;
            math_mant_raw = '0;
        end
    endcase
end

// Post-Operation Routing.
always_comb begin
    if (handle_special_wire) begin
        rd_fp   = special_result_wire;
        rd_int  = 64'd0;
        flags   = special_flags_wire;
    end 
    else if (datapath_sel_wire == SEL_CMP) begin
        rd_fp   = cmp_res_fp;   // FMIN/FMAX results
        rd_int  = cmp_res_int;  // FEQ/FLT/FLE results
        flags   = cmp_fflags;
    end
    else begin
        // This connects directly to output for now. 
        // For standard arithmetic results coming out of the normalizer
        rd_fp   = rounded_result;
        rd_int  = 64'd0;
        flags   = rounded_flags;
    end
end

assign fpu_stalled = div_busy;

endmodule
