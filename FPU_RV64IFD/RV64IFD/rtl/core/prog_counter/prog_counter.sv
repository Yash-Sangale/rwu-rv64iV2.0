`ifndef PC_H
`define PC_H 

`timescale 1ns / 1ps

module prog_counter (
    input logic clk,
    input logic rst_n,

    // control
    input logic        stall,           // hold PC
    input logic        redirect_valid,  // branch/jump taken
    input logic [XLEN-1:0] redirect_pc,     // target PC

    output logic [XLEN-1:0] pc,
    output logic [XLEN-1:0] pc_next
);


  // Next PC logic
  always_comb begin
    // Default: sequential execution
    pc_next = pc + 64'd4;

    // Redirect overrides sequential
    if (redirect_valid) begin
      pc_next = redirect_pc;
    end
  end


  // PC register
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pc <= 64'h0000_0000;  // IMEM base
    end else if (!stall) begin
      pc <= pc_next;
    end
  end

endmodule

`endif  // PC_H
