`timescale 1ns / 1ps

module fpu_fma(
    input fpu_pkg::fp64_t   a,
    input fpu_pkg::fp64_t   b,
    input fpu_pkg::fp64_t   c,
    input fpu_pkg::fpu_op_t op,

    output logic            sign_out,
    output logic [10:0]     exp_out,
    output logic [56:0]     mant_out
);
import fpu_pkg::*;

logic mul_sign, c_sign;

always_comb begin
    unique case(op)
        OP_FMADD:   begin mul_sign = a.sign ^ b.sign;       c_sign = c.sign; end
        OP_FMSUB:   begin mul_sign = a.sign ^ b.sign;       c_sign = ~c.sign; end
        OP_FNMADD:  begin mul_sign = ~(a.sign ^ b.sign);    c_sign = c.sign; end
        OP_FNMSUB:  begin mul_sign = ~(a.sign ^ b.sign);    c_sign = ~c.sign; end
        default:    begin mul_sign = a.sign ^ b.sign;       c_sign = c.sign; end
    endcase
end

logic [52:0] mant_a, mant_b, mant_c;
assign mant_a = {1'b1, a.mantissa};
assign mant_b = {1'b1, b.mantissa};
assign mant_c = {1'b1, c.mantissa};

logic [105:0] mant_prod;
assign mant_prod = {53'd0, mant_a} * {53'd0, mant_b};

logic signed [13:0] exp_prod;
assign exp_prod = $signed({3'b0, a.exponent}) + $signed({3'b0, b.exponent}) - 14'sd1023;

// -----------------------------------------------------------------------
// 1. ANCHORED ALIGNMENT
// -----------------------------------------------------------------------
// We force the '1.0' hidden bit of BOTH numbers to sit exactly at index 104.
logic [160:0] base_prod, base_c;
assign base_prod = {55'd0, mant_prod};         // mant_prod[104] is the hidden bit
assign base_c    = {56'd0, mant_c, 52'd0};     // mant_c[52] shifted by 52 puts it at 104

logic signed [13:0] exp_c, exp_diff;
assign exp_c = $signed({3'b0, c.exponent});

logic [160:0] aligned_prod, aligned_c;
logic signed [13:0] common_exp;

always_comb begin
    exp_diff = exp_prod - exp_c;
    
    // We only ever shift the smaller number to the RIGHT. 
    // This protects our MSB boundary at index 104/105.
    if (exp_diff > 0) begin
        aligned_prod = base_prod;
        aligned_c    = base_c >> exp_diff;
        common_exp   = exp_prod;
    end else begin
        aligned_c    = base_c;
        aligned_prod = base_prod >> (-exp_diff);
        common_exp   = exp_c;
    end
end

// Add/Sub step
logic [160:0] sum;
logic         final_sign;

always_comb begin
    if (mul_sign == c_sign) begin
        sum = aligned_prod + aligned_c;
        final_sign = mul_sign;
    end else begin
        if (aligned_prod >= aligned_c) begin
            sum = aligned_prod - aligned_c;
            final_sign = mul_sign;
        end else begin
            sum = aligned_c - aligned_prod;
            final_sign = c_sign;
        end
    end
end

// leading zero and single normalization
logic [7:0]         lz_count;
logic [160:0]       norm_sum;
logic [55:0]        ext_mant;
logic               sticky;
logic signed [13:0] final_exp;

always_comb begin
    // A. Find the leading 1
    lz_count = 8'd161; 
    for (int i = 160; i >= 0; i--) begin
        if (sum[i] == 1'b1) begin
            lz_count = 160 - i;
            break;
        end
    end

    // B. Extract and Adjust Exponent
    if (lz_count == 161) begin
        // Total cancellation (Result is exactly 0.0)
        ext_mant  = '0;
        sticky    = 1'b0;
        final_exp = '0;
    end else begin
        norm_sum  = sum << lz_count;
        ext_mant  = norm_sum[160:105];
        sticky    = |norm_sum[104:0];
        
        // Exponent Math: 
        // If the leading 1 was exactly at our anchor (104), lz_count is 56. 
        // 56 - 56 = 0 offset (final_exp = common_exp).
        final_exp = common_exp + 14'sd56 - $signed({6'b0, lz_count});
    end
    
    // C. Saturation
    if (final_exp <= 0) begin
        exp_out = 11'd0;             
    end else if (final_exp >= 14'sd2047) begin
        exp_out = 11'd2047;          
    end else begin
        exp_out = final_exp[10:0];   
    end
    
    // D. Pack for fpu_normalize
    sign_out = final_sign;
    mant_out = {1'b0, ext_mant[55:1], ext_mant[0] | sticky};
end

endmodule