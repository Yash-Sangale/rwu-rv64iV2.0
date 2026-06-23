`timescale 1ns / 1ps

module fpu_mul(
    input  fpu_pkg::fp64_t a,
    input  fpu_pkg::fp64_t b,
    
    output logic           sign_out,
    output logic [10:0]    exp_out,
    output logic [56:0]    mant_out // 57 bits to match the adder's output!
);

    assign sign_out = a.sign ^ b.sign;

    // mantissa multiplication (53 bits * 53 bits = 106 bits)
    logic [52:0] mant_a, mant_b;
    assign mant_a = {1'b1, a.mantissa}; // hidden bit
    assign mant_b = {1'b1, b.mantissa}; // hidden bit

    logic [105:0] product;
    assign product = {53'd0, mant_a} * {53'd0, mant_b};

    // exponent addition (subtract bias)
    logic signed [12:0] exp_sum;
    logic signed [12:0] exp_adj; // NEW: Temporary holding wire for the post-carry exponent
    
    assign exp_sum = $signed({2'b0, a.exponent}) + $signed({2'b0, b.exponent}) - 13'sd1023;

    // Pre-Normalization & Sticky Bit Extraction
    logic [55:0] norm_mant; 
    logic        sticky;

    always_comb begin
        if (product[105]) begin
            // Carry occurred. Take bits [105:50], hidden bit is at [55].
            norm_mant = product[105:50];
            sticky    = |product[49:0]; // Smash all dropped bits into sticky
            exp_adj   = exp_sum + 13'sd1;
        end else begin
            // No carry. Take bits [104:49], hidden bit is at [55].
            norm_mant = product[104:49];
            sticky    = |product[48:0];
            exp_adj   = exp_sum;
        end
        
        if (exp_adj <= 0) begin
            exp_out = 11'd0;             // Underflow
        end else if (exp_adj >= 13'sd2047) begin
            exp_out = 11'd2047;          // Overflow
        end else begin
            exp_out = exp_adj[10:0];     // Normal case, safe to truncate
        end
    end

    // packing into the standard 57-bit datapath format for fpu_normalize
    always_comb begin
        // [56]    = 0 (No carry for normalizer to handle, we just did it)
        // [55:1]  = norm_mant[55:1] (Hidden + Frac + G + R)
        // [0]     = norm_mant[0] | sticky (Combine bottom bit with our infinite sticky net)
        mant_out = {1'b0, norm_mant[55:1], norm_mant[0] | sticky};
    end

endmodule