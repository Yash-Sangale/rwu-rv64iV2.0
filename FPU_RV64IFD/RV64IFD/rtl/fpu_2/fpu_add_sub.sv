`timescale 1ns / 1ps

/*********************************************************************************
 * File Name:    fpu_add_sub.sv
 * Description:  Does the actual addition and subtraction of the aligned numbers.
 *
 * Inputs:       a, b, is_sub (tells it whether to add or subtract)
 * Outputs:      sign, exp_out, mant_sum_out (the raw 54-bit math result)
 *
 * Notes:        This module DOES NOT output a packed 64-bit float. It outputs 
 *               a 54-bit sum so we don't accidentally throw away the carry-out 
 *               or the hidden bit before normalization happens.
 *********************************************************************************/

module fpu_add_sub(
    input fpu_pkg::fp64_t   a,
    input fpu_pkg::fp64_t   b,
    input logic             is_sub,
    
    output logic            sign,
    output logic [10:0]     exp_out,
    output logic [56:0]     mant_sum_out
    );
    
import fpu_pkg::*; 

// Effective sign to determine the kind of operation to be performed.
// For e.g: A - (-B), here is_sub = 1 and b.sign = 1
/// So, eff_sign = 0, effectively making it an Addition operation
logic eff_sign;
assign eff_sign = is_sub ? ~b.sign : b.sign;

// Assigning Mantissa (Adding Hidden Bit)
logic [52:0] mant_a, mant_b;
assign mant_a = {1'b1, a.mantissa};
assign mant_b = {1'b1, b.mantissa};

// Alignment
logic [10:0] exp_common;
logic [55:0] mant_a_aligned, mant_b_aligned;

fpu_align align (
    .exp_a(a.exponent),
    .exp_b(b.exponent),
    .mant_a(mant_a),
    .mant_b(mant_b),

    .mant_a_out(mant_a_aligned),
    .mant_b_out(mant_b_aligned),
    .exp_out(exp_common)
);   

// ADD / SUB Core Function
logic [56:0]    mant_sum;   // Including carry bit
logic           sign_out;

always_comb begin

    // Check if signs of both numbers are the same 
    // (both +ve or -ve), simply add the mantissas
    if (a.sign == eff_sign) begin
        mant_sum = mant_a_aligned + mant_b_aligned;
        sign_out = a.sign; 
    end
    // If signs are unequal, do subtraction
    // According to mantissa comparison!
    else begin
        if(mant_a_aligned >= mant_b_aligned) begin
            mant_sum = mant_a_aligned - mant_b_aligned;
            sign_out = a.sign; 
        end
        
        else begin
            mant_sum = mant_b_aligned - mant_a_aligned;
            sign_out = eff_sign; 
        end 
    end 
end          


// Packing Results
assign sign         = sign_out;
assign exp_out      = exp_common;
assign mant_sum_out = mant_sum;

endmodule