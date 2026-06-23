`timescale 1ns / 1ps

module fpu_div_sqrt(
    input  logic                    clk,
    input  logic                    rst,
    
    // Handshake Signals
    input  logic                    start,
    output logic                    busy,
    output logic                    done,
    
    // Data Signals
    input  fpu_pkg::fp64_t          a,
    input  fpu_pkg::fp64_t          b,
    input  fpu_pkg::fpu_op_t        op,
    
    // Packaged Outputs for fpu_normalize
    output logic                    sign_out,
    output logic [10:0]             exp_out,
    output logic [56:0]             mant_out 
);
    import fpu_pkg::*;

    typedef enum logic [1:0] { IDLE, CALC, DONE } state_t;
    state_t state, next_state;

    logic [5:0]          bit_count;
    logic                reg_sign;
    logic signed [14:0]  reg_exp; 

    // =========================================================================
    // ONE-SHOT START FILTER (Note C Fortress Interlock)
    // =========================================================================
    logic start_q;
    logic start_pulse;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) start_q <= 1'b0;
        else     start_q <= start;
    end

    // High for exactly 1 clock cycle when 'start' transitions from 0 -> 1
    assign start_pulse = start & ~start_q; 

    // --- The Unified 112-Bit Datapath ---
    logic [111:0]        remainder; 
    logic [55:0]         divisor;
    logic [54:0]         quotient;

    // Subnormal / Zero protection
    logic hidden_a, hidden_b;
    assign hidden_a = (a.exponent != 11'd0);
    assign hidden_b = (b.exponent != 11'd0);

    logic [52:0] mant_a, mant_b;
    assign mant_a = {hidden_a, a.mantissa};
    assign mant_b = {hidden_b, b.mantissa};

    // SQRT Exponent Parity Check
    logic is_true_exp_odd;
    assign is_true_exp_odd = ~a.exponent[0];

    // SQRT Radicand Alignment
    logic [55:0] sqrt_tail_load;
    assign sqrt_tail_load = is_true_exp_odd ? {mant_a, 3'b000} : {1'b0, mant_a, 2'b00};

    // --- The Math Window ---
    logic [55:0] cmp_window;
    logic [55:0] active_subtrahend;
    logic        can_sub;
    logic [55:0] next_window;

    assign cmp_window = remainder[111:56];

    always_comb begin
        if (op == OP_FSQRT) begin
            active_subtrahend = {quotient[53:0], 2'b01}; 
        end else begin
            active_subtrahend = divisor;
        end
    end

    assign can_sub     = (cmp_window >= active_subtrahend);
    assign next_window = can_sub ? (cmp_window - active_subtrahend) : cmp_window;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) state <= IDLE;
        else     state <= next_state;
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            bit_count <= '0;
            reg_sign  <= 1'b0;
            reg_exp   <= '0;
            remainder <= '0;
            divisor   <= '0;
            quotient  <= '0;
            done      <= 1'b0;
            busy      <= 1'b0;
        end else begin
            done <= 1'b0; 

            case (state)
                IDLE: begin
                    busy <= 1'b0;
                    if (start_pulse) begin // <--- PROTECTED TRIGGER
                        busy      <= 1'b1;
                        bit_count <= 6'd55; 
                        quotient  <= '0;

                        if (op == OP_FDIV) begin
                            reg_sign  <= a.sign ^ b.sign;
                            reg_exp   <= $signed({4'b0, a.exponent}) - $signed({4'b0, b.exponent}) + 15'sd1023;
                            divisor   <= {1'b0, mant_b, 2'b00};
                            remainder <= {1'b0, mant_a, 2'b00, 56'd0}; 
                        end 
                        else if (op == OP_FSQRT) begin
                            reg_sign  <= a.sign; 
                            reg_exp   <= ($signed({4'b0, a.exponent} - 15'sd1023) >>> 1) + 15'sd1023;
                            divisor   <= '0; 
                            remainder <= {56'd0, sqrt_tail_load} << 2;
                        end
                    end
                end

                CALC: begin
                    busy <= 1'b1;
                    if (op == OP_FSQRT) begin
                        remainder <= {next_window, remainder[55:0]} << 2;
                    end else begin
                        remainder <= {next_window, remainder[55:0]} << 1;
                    end
                    
                    quotient  <= {quotient[53:0], can_sub};
                    bit_count <= bit_count - 1;
                end

                DONE: begin
                    busy <= 1'b0;
                    done <= 1'b1; 
                end
            endcase
        end
    end

    always_comb begin
        next_state = state;
        case (state)
            IDLE: if (start_pulse && ((op == OP_FDIV) | (op == OP_FSQRT))) next_state = CALC; // <--- PROTECTED TRIGGER
            CALC: if (bit_count == 1)                                      next_state = DONE; 
            DONE:                                                          next_state = IDLE;
            default:                                                       next_state = IDLE;
        endcase
    end

    // --- Normalization & Output Formatting ---
    logic signed [14:0] norm_exp;
    logic [56:0]        norm_mant; 
    logic               sticky;

    always_comb begin
        sign_out = reg_sign;
        sticky   = (remainder != 112'd0);

        if (quotient[54] == 1'b1) begin
            norm_mant = {1'b0, quotient[54:0], sticky};
            norm_exp  = reg_exp;
        end else begin
            norm_mant = {1'b0, quotient[53:0], 1'b0, sticky};
            norm_exp  = reg_exp - 15'sd1;
        end

        if (norm_exp <= 0) begin
            exp_out = 11'd0;             
        end else if (norm_exp >= 15'sd2047) begin
            exp_out = 11'd2047;          
        end else begin
            exp_out = norm_exp[10:0];    
        end
        
        mant_out = norm_mant;
    end
endmodule