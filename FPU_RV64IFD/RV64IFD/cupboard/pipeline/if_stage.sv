`ifndef IF_STAGE_SV
`define IF_STAGE_SV 

`timescale 1ns / 1ps

`include "isa_pkg.sv"
`include "types_pkg.sv"
`include "pc.sv"

module if_stage (
    input logic clk,
    input logic rst_n,

    // control
    input logic        stall,
    input logic        flush,
    input logic [XLEN-1:0] redirect_pc,
    input logic        redirect_valid,

    // IMEM interface
    output logic        imem_cs,
    output logic [XLEN-1:0] imem_addr,
    input  logic [ILEN-1:0] imem_rdata,
    input  logic        imem_valid,
  // @note: what about parity error ?
    // to IF/ID reg
    output if_id_reg_t if_id_next
);
  
  // Program Counter (ONLY ONE SOURCE OF TRUTH)
  logic [63:0] pc;
  logic [63:0] pc_next;

  prog_counter u_pc (
      .clk(clk),
      .rst_n(rst_n),
      .stall(stall),
      .redirect_valid(redirect_valid),
      .redirect_pc(redirect_pc),
      .pc(pc),
      .pc_next(pc_next)
  );


  // IMEM interface
  assign imem_addr = pc;
  assign imem_cs   = !stall;


  // Align PC with IMEM latency
  logic [63:0] pc_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      pc_r <= '0;
    else if (!stall)
      pc_r <= pc;
  end
  
  // IF/ID output
  always_comb begin
    if_id_next.pc    = pc_r;        // aligned PC
    if_id_next.instr = imem_rdata;
    if_id_next.valid = imem_valid & !flush;
  end

endmodule

`endif