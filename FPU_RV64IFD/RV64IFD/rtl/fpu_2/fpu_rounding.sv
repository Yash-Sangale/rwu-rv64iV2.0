`timescale 1ns / 1ps

 
module fpu_rounding(
    input  logic                 sign,
    input  logic [10:0]          exp_in,
    input  logic [51:0]          mant_in, // The 52-bit normalized fraction
    
    // The Precision Bits (From fpu_normalize)
    input  logic                 guard,   // G
    input  logic                 rnd,     // R
    input  logic                 stky,    // S
    
    // Control
    input  fpu_pkg::fpu_frm_t    rm,      // Rounding Mode
    
    // Outputs
    output fpu_pkg::fp64_t       rd,      // Final packed 64-bit float
    output fpu_pkg::fpu_fflags_t flags    // IEEE-754 Exception Flags
);

import fpu_pkg::*;

// Constant Definitions for Overflow Handling
localparam logic [63:0] INF_POS     = 64'h7FF0_0000_0000_0000;
localparam logic [63:0] INF_NEG     = 64'hFFF0_0000_0000_0000;
localparam logic [63:0] MAX_FIN_POS = 64'h7FEF_FFFF_FFFF_FFFF;
localparam logic [63:0] MAX_FIN_NEG = 64'hFFEF_FFFF_FFFF_FFFF;

logic lsb;
logic round_up;
logic nx_flag;

always_comb begin
    lsb     = mant_in[0]; // LSB of kept significand for tie-breaking
    nx_flag = guard | rnd | stky;

    unique case (rm)
        RM_RNE:  round_up = guard & (rnd | stky | lsb);              // Round to Nearest, Ties to Even
        RM_RTZ:  round_up = 1'b0;                                    // Round toward Zero (Truncate)
        RM_RDN:  round_up = sign & (guard | rnd | stky);             // Round Down (-Inf)
        RM_RUP:  round_up = !sign & (guard | rnd | stky);            // Round Up (+Inf)
        RM_RMM:  round_up = guard;                                   // Round to Nearest, Ties to Max Mag
        default: round_up = guard & (rnd | stky | lsb);              // Default to RNE
    endcase
end

// 54-bit vector: [53] Carry, [52] Hidden Bit (1), [51:0] Mantissa
logic [53:0] sig53_rounded;

always_comb begin
    // Add the round_up bit to the 53-bit significand
    sig53_rounded = {2'b01, mant_in} + {53'd0, round_up};
end

// -------------------------------------------------------------------------
// 3. POST-ROUND NORMALIZATION
// -------------------------------------------------------------------------
logic [10:0] final_exp;
logic [51:0] final_frac;

always_comb begin
    // sig53_rounded[53] = 1 means the rounding increment caused an overflow
    // of the 53-bit significand; right-shift by 1, increment exponent.
    if (sig53_rounded[53]) begin
        final_exp  = exp_in + 11'd1;
        final_frac = sig53_rounded[52:1];
    end else begin
        final_exp  = exp_in;
        final_frac = sig53_rounded[51:0];
    end
end

// -------------------------------------------------------------------------
// 4. OVERFLOW HANDLING & FINAL PACKING
// -------------------------------------------------------------------------
logic of_flag;
assign of_flag = (final_exp == 11'h7FF);

always_comb begin
    // Initialize flags
    flags = '0;
    
    if (of_flag) begin
        // If the exponent blew past the max limit, apply IEEE overflow rules
        unique case (rm)
            RM_RNE:  rd = sign ? fp64_t'(INF_NEG)     : fp64_t'(INF_POS);
            RM_RTZ:  rd = sign ? fp64_t'(MAX_FIN_NEG) : fp64_t'(MAX_FIN_POS);
            RM_RDN:  rd = sign ? fp64_t'(INF_NEG)     : fp64_t'(MAX_FIN_POS);
            RM_RUP:  rd = sign ? fp64_t'(MAX_FIN_NEG) : fp64_t'(INF_POS);
            RM_RMM:  rd = sign ? fp64_t'(INF_NEG)     : fp64_t'(INF_POS);
            default: rd = sign ? fp64_t'(INF_NEG)     : fp64_t'(INF_POS);
        endcase
        
        flags.FF_OF = 1'b1; // Raise Overflow
        flags.FF_NX = 1'b1; // Overflow is inherently inexact
        
    end else begin
        // Standard packing
        rd.sign     = sign;
        rd.exponent = final_exp;
        rd.mantissa = final_frac;
        flags.FF_NX = nx_flag;
    end
end

endmodule