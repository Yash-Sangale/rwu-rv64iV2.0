// Interrupt controller — fixed priority, IRQ[0] highest.
//
// Register map (byte offsets from IRQ_CTL_BASE):
//   0x00  IE      [N_IRQ-1:0]  interrupt enable          R/W
//   0x08  IP      [N_IRQ-1:0]  interrupt pending         R / W1C
//   0x10  VEC_LO  [31:0]       ISR address bits [31:0]   R/W
//   0x18  VEC_HI  [31:0]       ISR address bits [63:32]  R/W
//   0x20  ACK     [N_IRQ-1:0]  W1C alias of IP           W
//
// irq_out: level, asserted while any (IP & IE) bit is set.
// irq_vec: 64-bit ISR address programmed by software.

`timescale 1ns/1ps

`ifndef IRQ_CTL_SV
`define IRQ_CTL_SV

`include "isa_pkg.sv"
`include "wb_pkg.sv"
`include "mem_map_pkg.sv"

import isa_pkg::*;
import wb_pkg::*;
import mem_map_pkg::*;


module irq_ctrl #(
    parameter int unsigned N_IRQ = 8
) (
    input  logic clk,
    input  logic rst_n,

    input  wb_req_t  wb_req,
    output wb_resp_t wb_resp,

    input  logic [N_IRQ-1:0] irq_src,

    output logic        irq_out,
    output logic [63:0] irq_vec
);

    localparam logic [7:0] REG_IE     = 8'h00;
    localparam logic [7:0] REG_IP     = 8'h08;
    localparam logic [7:0] REG_VEC_LO = 8'h10;
    localparam logic [7:0] REG_VEC_HI = 8'h18;
    localparam logic [7:0] REG_ACK    = 8'h20;

    logic [N_IRQ-1:0] ie_r;
    logic [N_IRQ-1:0] ip_r;
    logic [63:0]      vec_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ie_r  <= '0;
            ip_r  <= '0;
            vec_r <= '0;
        end else begin
            // latch level-triggered sources
            ip_r <= ip_r | irq_src;

            if (wb_req.cyc && wb_req.stb && wb_req.we) begin
                unique case (wb_req.adr[7:0])
                    REG_IE:     ie_r         <= wb_req.dat[N_IRQ-1:0];
                    REG_IP:     ip_r         <= ip_r & ~wb_req.dat[N_IRQ-1:0];
                    REG_VEC_LO: vec_r[31:0]  <= wb_req.dat[31:0];
                    REG_VEC_HI: vec_r[63:32] <= wb_req.dat[31:0];
                    REG_ACK:    ip_r         <= ip_r & ~wb_req.dat[N_IRQ-1:0];
                    default:    begin end
                endcase
            end
        end
    end

    always_comb begin
        wb_resp = WB_RESP_IDLE;
        if (wb_req.cyc && wb_req.stb) begin
            wb_resp.ack = 1'b1;
            if (!wb_req.we) begin
                unique case (wb_req.adr[7:0])
                    REG_IE:     wb_resp.dat = {{(XLEN-N_IRQ){1'b0}}, ie_r};
                    REG_IP:     wb_resp.dat = {{(XLEN-N_IRQ){1'b0}}, ip_r};
                    REG_VEC_LO: wb_resp.dat = {32'b0, vec_r[31:0]};
                    REG_VEC_HI: wb_resp.dat = {32'b0, vec_r[63:32]};
                    default:    wb_resp.err = 1'b1;
                endcase
            end
        end
    end

    assign irq_out = |(ip_r & ie_r);
    assign irq_vec = vec_r;

endmodule

`endif
