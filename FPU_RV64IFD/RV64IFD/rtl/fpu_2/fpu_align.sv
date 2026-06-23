`timescale 1ns / 1ps

module fpu_align(
    
    input logic [10:0] exp_a,
    input logic [10:0] exp_b,
    
    input logic [52:0] mant_a,  // Hidden bit + 52
    input logic [52:0] mant_b,
    
    output logic [55:0] mant_a_out, // Hidden + 52 + G + R + S
    output logic [55:0] mant_b_out,
    output logic [10:0] exp_out
    
    );
    
    
logic [10:0] exp_diff;

logic s_bit;
logic [55:0] mant_a_ext;
logic [55:0] mant_b_ext;

// For guard, round and sticky bits
assign mant_a_ext = {mant_a, 3'b000}; 
assign mant_b_ext = {mant_b, 3'b000};

always_comb begin

    mant_a_out  =   mant_a_ext;
    mant_b_out  =   mant_b_ext;
    exp_out     =   exp_a;
    s_bit       =   1'b0;
    if (exp_a > exp_b) begin
        exp_diff = exp_a - exp_b;
        exp_out  = exp_a;
        
        // Catch the Sticky Bit: Check if any bits we are about to shift away are '1'
        // Create a mask of 1s equal to the shift amount
        if (exp_diff < 56) begin
            s_bit = |(mant_b_ext & ((56'b1 << exp_diff) - 1));
            mant_b_out = (mant_b_ext >> exp_diff) | s_bit;
        end else begin
            // If we shift by more than 56, the whole number becomes the sticky bit
            s_bit = |mant_b_ext;
            mant_b_out = {55'd0, s_bit};
        end
        
    end else if (exp_b > exp_a) begin
        exp_diff = exp_b - exp_a;
        exp_out  = exp_b;
        
        // Catch the Sticky Bit
        if (exp_diff < 56) begin
            s_bit = |(mant_a_ext & ((56'b1 << exp_diff) - 1));
            mant_a_out = (mant_a_ext >> exp_diff) | s_bit;
        end else begin
            s_bit = |mant_a_ext;
            mant_a_out = {55'd0, s_bit};
        end
    end     
end

endmodule
