`timescale 1ns / 1ps

module fpu_normalize(
    input  logic        sign_in,
    input  logic [10:0] exp_in,
    input  logic [56:0] mant_in, // 56 bits: [56] Carry, [55] Hidden, [54:3] Mantissa, [2:0] GRS

    output logic        sign_out,
    output logic [10:0] exp_out,
    output logic [51:0] mant_out, // Standard 52-bit fraction
    
    output logic        guard_out,
    output logic        round_out,
    output logic        sticky_out
);

    logic [56:0] shifted_mant;
    logic [10:0] adjusted_exp;
    logic [5:0]  shift_amt; // Max shift is 57, which fits in 6 bits

    always_comb begin
        // Default assignments to prevent latches
        shifted_mant = mant_in;
        adjusted_exp = exp_in;
        shift_amt    = '0;

        // Result is exactly 0
        if (mant_in == 57'b0) begin
            shifted_mant = '0;
            adjusted_exp = '0;
        end
        // Overflow (Carry bit is 1)
        else if (mant_in[56] == 1'b1) begin
            shifted_mant = mant_in >> 1;
            shifted_mant[0] = mant_in[1] | mant_in[0];            
            adjusted_exp = exp_in + 1;
        end
        // Underflow / Leading Zeros (Need to shift left)
        else begin
            // Find the first '1' starting from bit 52 downwards
            for (int i = 55; i >= 0; i--) begin
                if (mant_in[i] == 1'b1) begin
                    shift_amt = 55 - i;
                    break; 
                end
            end
            
            // Apply the left shift
            shifted_mant = mant_in << shift_amt;
            adjusted_exp = exp_in - shift_amt;
        end
    end

    // Pack the final normalized outputs
    assign sign_out = sign_in;
    assign exp_out  = adjusted_exp;
    
    // Drop the hidden bit (now guaranteed to be at bit 52) and output the fraction
    assign mant_out = shifted_mant[54:3]; 

    assign guard_out  = shifted_mant[2];
    assign round_out  = shifted_mant[1];
    assign sticky_out = shifted_mant[0];
    
endmodule