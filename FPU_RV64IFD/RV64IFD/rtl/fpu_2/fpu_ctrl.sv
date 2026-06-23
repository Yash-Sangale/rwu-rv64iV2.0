`timescale 1ns / 1ps

module fpu_ctrl(
    
    input fpu_pkg::fpu_op_t         op,
    input fpu_pkg::fp64_t           rs1,
    input fpu_pkg::fp64_t           rs2,
    input fpu_pkg::fp64_t           rs3,
    
    // Outputs to the datapath blocks
    output logic                    is_sub,
    output fpu_pkg::fpu_res_sel_t   datapath_select,
    
    output logic                    handle_special,
    output fpu_pkg::fp64_t          special_result,
    output fpu_pkg::fpu_fflags_t    special_flags,

    output logic [9:0]              rs1_mask_out,
    output logic [9:0]              rs2_mask_out,
    output logic [9:0]              rs3_mask_out
);
    
import fpu_pkg::*;

// Classifying inputs for Special Case handling
logic [9:0] rs1_mask;
logic [9:0] rs2_mask;
logic [9:0] rs3_mask;

fpu_class classify_rs1 (
    .a(rs1),
    .mask(rs1_mask)
);  

fpu_class classify_rs2 (
    .a(rs2),
    .mask(rs2_mask)
);  

fpu_class classify_rs3 (
    .a(rs3),
    .mask(rs3_mask)
); 

assign rs1_mask_out = rs1_mask;
assign rs2_mask_out = rs2_mask;
assign rs3_mask_out = rs3_mask;

// Control Path
logic rs1_is_nan, rs2_is_nan, rs3_is_nan;
logic rs1_is_inf, rs2_is_inf;
logic rs1_is_zero, rs2_is_zero;

assign rs1_is_nan = rs1_mask[CLASS_QNAN] | rs1_mask[CLASS_SNAN];
assign rs2_is_nan = rs2_mask[CLASS_QNAN] | rs2_mask[CLASS_SNAN];
assign rs3_is_nan = rs3_mask[CLASS_QNAN] | rs3_mask[CLASS_SNAN];

assign rs1_is_inf  = rs1_mask[CLASS_NEG_INF]  | rs1_mask[CLASS_POS_INF];
assign rs2_is_inf  = rs2_mask[CLASS_NEG_INF]  | rs2_mask[CLASS_POS_INF];
assign rs1_is_zero = rs1_mask[CLASS_NEG_ZERO] | rs1_mask[CLASS_POS_ZERO];
assign rs2_is_zero = rs2_mask[CLASS_NEG_ZERO] | rs2_mask[CLASS_POS_ZERO];

always_comb begin
    // Default assignments
    handle_special  = 1'b0;
    datapath_select = SEL_NONE;
    special_flags   = 0;
    special_result  = 0;
    is_sub          = 1'b0;
    
    case (op)
    
        // F.ADD | F.SUB
        OP_FADD, OP_FSUB: begin    
            is_sub                  = (op == OP_FSUB);
            datapath_select         = SEL_ADDER;
            
            // NaN Check - Sets the special values flag 
            // and redirects to the special result 
            // instead of the output from the operation block
            if (rs1_is_nan || rs2_is_nan) begin
                handle_special      = 1'b1;
                special_result      = 64'h7FF8_0000_0000_0000; // Canonical NaN
                if (rs1_mask[CLASS_SNAN] || rs2_mask[CLASS_SNAN]) special_flags.FF_NV 
                                    = 1'b1;
            end
 
            // TODO: Implement similarly for Infinity check   
            
        end
        
        OP_FMUL: begin
            datapath_select         = SEL_MUL;
        
            // NaN Check
            if (rs1_is_nan || rs2_is_nan) begin
                handle_special      = 1'b1;
                special_result      = 64'h7FF8_0000_0000_0000; // Canonical NaN
                if (rs1_mask[CLASS_SNAN] || rs2_mask[CLASS_SNAN]) special_flags.FF_NV 
                                    = 1'b1;
            end
            
            // TODO: Implement similarly for Infinity check   
                
        end            
        
        OP_FDIV: begin
            datapath_select = SEL_DIV_SQRT;
        
            if (rs1_is_nan || rs2_is_nan || (rs1_is_zero && rs2_is_zero) || (rs1_is_inf && rs2_is_inf)) begin
                handle_special = 1'b1;
                special_result = 64'h7FF8_0000_0000_0000; // QNAN
                if (rs1_mask[CLASS_SNAN] || rs2_mask[CLASS_SNAN] || (rs1_is_zero && rs2_is_zero) || (rs1_is_inf && rs2_is_inf)) 
                    special_flags.FF_NV = 1'b1;
            end else if (rs2_is_zero) begin
                handle_special = 1'b1;
                special_result = {rs1.sign ^ rs2.sign, 63'h7FF0_0000_0000_0000}; // Inf
                special_flags.FF_DZ = 1'b1;
            end else if (rs1_is_inf || rs1_is_zero || rs2_is_inf) begin
                handle_special = 1'b1;
                special_result = (rs1_is_inf) ? {rs1.sign ^ rs2.sign, 63'h7FF0_0000_0000_0000} : {rs1.sign ^ rs2.sign, 63'd0};
            end
        end

        OP_FSQRT: begin
            datapath_select = SEL_DIV_SQRT;
            
            if (rs1_is_nan || (rs1.sign && !rs1_is_zero)) begin
                handle_special = 1'b1;
                special_result = 64'h7FF8_0000_0000_0000; // QNAN
                if (rs1_mask[CLASS_SNAN] || (rs1.sign && !rs1_is_zero)) special_flags.FF_NV = 1'b1;
            end else if (rs1_is_inf && !rs1.sign) begin
                handle_special = 1'b1;
                special_result = {1'b0, 63'h7FF0_0000_0000_0000}; // +Inf
            end else if (rs1_is_zero) begin
                handle_special = 1'b1;
                special_result = {rs1.sign, 63'd0}; // +/- 0
            end
        end


        OP_FCLASS: begin
            // FCLASS.D result for rs1 is already available above
            // It doesnt need a datapath. 
            datapath_select         = SEL_NONE;     
            
            // Since data is already available
            // Bypass using special values flag
            handle_special          = 1'b1;
            
            // Need to pad as result is 64-bit
            special_result          = {54'b0, rs1_mask};
            special_flags           = '0;   // No flags to raise
                                                
        end
            
        OP_FSGNJ, OP_FSGNJN, OP_FSGNJX: begin
            datapath_select = SEL_NONE;     // Bypass math pipeline
            handle_special  = 1'b1;         // Direct output
            special_flags   = '0;           // No exceptions for these ops

            unique case (op)
                OP_FSGNJ:   special_result = {rs2.sign, rs1.exponent, rs1.mantissa};
                OP_FSGNJN:  special_result = {~rs2.sign, rs1.exponent, rs1.mantissa};
                OP_FSGNJX:  special_result = {(rs1.sign ^ rs2.sign), rs1.exponent, rs1.mantissa};
                default:    special_result = rs1;
            endcase
        end

        OP_FEQ, OP_FLE, OP_FLT, OP_FMIN, OP_FMAX: begin
            datapath_select = SEL_CMP;
        end

        OP_FMADD, OP_FMSUB, OP_FNMADD, OP_FNMSUB: begin
            datapath_select = SEL_FMA;
            
            // NaN Check
            if (rs1_is_nan || rs2_is_nan || rs3_is_nan) begin
                handle_special          = 1'b1;
                special_result          = 64'h7FF8_0000_0000_0000; // Canonical NaN
                if (rs1_mask[CLASS_SNAN] || rs2_mask[CLASS_SNAN] || rs3_mask[CLASS_SNAN]) 
                    special_flags.FF_NV = 1'b1;
            end
        end

        default: begin
            datapath_select = SEL_NONE;
        end
                  
    endcase
end
endmodule
