`timescale 1ns / 1ps


module fpu_cmp(
    input fpu_pkg::fp64_t   rs1,
    input fpu_pkg::fp64_t   rs2,
    input fpu_pkg::fpu_op_t op,

    // coming from fpu_ctrl/class, no need to check again
    input  logic [9:0]      rs1_mask,
    input  logic [9:0]      rs2_mask,


    output fpu_pkg::fp64_t          rd_fp,      // write min/max result to floating poin register
    output logic [63:0]             rd_int,     // write comparison resilts to integer register 
    output fpu_pkg::fpu_fflags_t    flags
);

import fpu_pkg::*;

// extract only magnitudes
logic [62:0] mag1;
logic [62:0] mag2;

assign mag1 = rs1 [62:0];
assign mag2 = rs2 [62:0];

// preparing flags
logic is_nan_1, is_nan_2, is_snan_1, is_snan_2;
logic is_zero_1, is_zero_2;

assign is_nan_1  = rs1_mask[CLASS_QNAN] | rs1_mask[CLASS_SNAN];
assign is_nan_2  = rs2_mask[CLASS_QNAN] | rs2_mask[CLASS_SNAN];
assign is_snan_1 = rs1_mask[CLASS_SNAN];
assign is_snan_2 = rs2_mask[CLASS_SNAN];
assign is_zero_1 = rs1_mask[CLASS_POS_ZERO] | rs1_mask[CLASS_NEG_ZERO];
assign is_zero_2 = rs2_mask[CLASS_POS_ZERO] | rs2_mask[CLASS_NEG_ZERO];

// magnitude comparison
logic mag_eq, mag_lt, mag_gt;
logic cmp_eq, cmp_lt;

assign mag_eq = (mag1 == mag2);
assign mag_lt = (mag1 < mag2 );
assign mag_gt = (mag1 > mag2 );


always_comb begin

    // Acc. to IEEE 754, +0.0 == -0.0
    cmp_eq = mag_eq || (is_zero_1 && is_zero_2);

    // rs1: -ve, rs2: +ve (or both zero)
    if (rs1.sign && !rs2.sign)
        cmp_lt = (!is_zero_1 || !is_zero_2) ? 1'b1 : 1'b0;  
    // rs1: +ve, rs2: -ve  
    else if (!rs1.sign && rs2.sign)
        cmp_lt = 1'b0;
    // both positive, choose larger one
    else if (!rs1.sign) 
        cmp_lt = mag_lt;
    // both negative, reverse magnitude
    else
        cmp_lt = !mag_lt && !mag_eq;
end

// routing and exception handling

always_comb begin
    rd_fp   = rs1;
    rd_int  = '0;
    flags   = '0;

    // If either is NaN, all integer comparisons output 0 and flag NV.
    if (is_nan_1 || is_nan_2) begin

        // FEQ only raises NV for Signaling NaNs. FLT/FLE raise NV for ANY NaN.
        if (op == OP_FEQ || op == OP_FMIN || op == OP_FMAX) begin
            if (is_snan_1 || is_snan_2) flags.FF_NV = 1'b1;
        end 
        else flags.FF_NV = 1'b1; 
        
        if (op == OP_FMIN || op == OP_FMAX) begin
            if (!is_nan_1)      rd_fp = rs1;
            else if (!is_nan_2) rd_fp = rs2;
            else                rd_fp = fp64_t'(64'h7FF8_0000_0000_0000); // Canonical NaN
        end
    end 
    
    else begin
        unique case (op)
            OP_FEQ:  rd_int = {63'd0, cmp_eq};
            OP_FLT:  rd_int = {63'd0, cmp_lt};
            OP_FLE:  rd_int = {63'd0, cmp_lt | cmp_eq};
            OP_FMIN: rd_fp  = cmp_lt ? rs1 : rs2;
            OP_FMAX: rd_fp  = cmp_lt ? rs2 : rs1;
            default: ; 
        endcase
    end
end

endmodule