`timescale 1ns / 1ps

/*********************************************************************************
 * File Name:    fpu_class.sv
 * Description:  Looks at the raw bits of a float and figures out exactly what 
 *               kind of number it is (like Infinity, Zero, or a NaN).
 *
 * Inputs:       a (the 64-bit float to check)
 * Outputs:      mask (a 10-bit wire saying which category the number falls into)
 *
 * Notes:        It uses parallel bitwise logic instead of if/else statements 
 *               so it can classify the number instantly in one clock cycle.
 *********************************************************************************/

module fpu_class(

    input fpu_pkg::fp64_t a,
    
    output logic [9:0] mask
    );
    
import fpu_pkg::*;

logic        sign;
logic [10:0] exp;
logic [51:0] mant;
    
assign sign = a.sign;
assign exp  = a.exponent;
assign mant = a.mantissa;

logic expOnes, expZeroes, mantZeroes, mantMsb;

// Non Branched Method
assign expOnes = & exp;         // All exponents bits '1' check
assign expZeroes = ~| exp;      // All exponents bits '0' check
assign mantZeroes = ~| mant;    // All mantissa bits '0' check
assign mantMsb = mant[51];      // MSB of Mantissa for NaN check

assign mask[CLASS_NEG_INF]      =  sign &  expOnes  &  mantZeroes;
assign mask[CLASS_NEG_NORM]     =  sign & ~expOnes  & ~expZeroes;
assign mask[CLASS_NEG_SUB]      =  sign &  expZeroes & ~mantZeroes;
assign mask[CLASS_NEG_ZERO]     =  sign &  expZeroes &  mantZeroes;
assign mask[CLASS_POS_ZERO]     = ~sign &  expZeroes &  mantZeroes;
assign mask[CLASS_POS_SUB]      = ~sign &  expZeroes & ~mantZeroes;
assign mask[CLASS_POS_NORM]     = ~sign & ~expOnes  & ~expZeroes;
assign mask[CLASS_POS_INF]      = ~sign &  expOnes  &  mantZeroes;
assign mask[CLASS_SNAN]         = (expOnes) & (~mantZeroes) & ~mantMsb;
assign mask[CLASS_QNAN]         = (expOnes) & (~mantZeroes) & mantMsb;

// Branched Method (Remove)
//    if (exp == 11'h7FF) begin
//        if (mant == 52'h000) begin                                  // Inf Check (All Mantissa bits are '0'
//            if (sign)               mask [CLASS_NEG_INF] = 1'b1;    // -ve Inf
//            else                    mask [CLASS_POS_INF] = 1'b1;    // +ve Inf
//        end
        
//        else begin                                                  // NaN Check (At least 1 Mantissa bit is '1')
//            if (mant[51] == 1'b1)   mask [CLASS_QNAN] = 1'b1;       // Quiet NaN  
//            else                    mask [CLASS_SNAN] = 1'b1;       // Signalling NaN
//        end
//    end
        
//    else if (exp == 11'h000) begin
//        if (mant == 52'h000) begin                                  // Inf Check (All Mantissa bits are '0')
//            if (sign)               mask [CLASS_NEG_ZERO] = 1'b1;   // -ve Zero
//            else                    mask [CLASS_POS_ZERO] = 1'b1;   // +ve Zero
//        end
        
//        else begin                                                  // Subnormal Numebrs (At least 1 Mantissa bit is '1')
//            if (sign)       mask [CLASS_NEG_SUB] = 1'b1;    // -ve Subnormal  
//            else                    mask [CLASS_POS_SUB] = 1'b1;    // +ve Subormal
//        end
//    end
    
//    else begin                                                      // Nomral Numbers
//        if (sign)                   mask[CLASS_NEG_NORM] = 1'b1;    // -ve Normal
//        else                        mask[CLASS_POS_NORM] = 1'b1;    // +ve Normal
//    end

endmodule
