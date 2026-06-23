`timescale 1ns / 1ps

`ifndef GPIO_SV
`define GPIO_SV

`include "isa_pkg.sv"
`include "wb_pkg.sv"

import isa_pkg::*;
import wb_pkg::*;

// GPIO0 — Wishbone B4 Classic slave, ported register set from professor's design.
//
// Register map (byte offsets from GPIO0_BASE):
//   0x00  ID      read-only, reset=0x1
//   0x08  DIR     1=output, 0=input
//   0x10  DATA    write: drive output pins; read: current pin state (muxed)
//   0x18  IRQSS   IRQ source status — W1C
//   0x20  IRQSM   IRQ source mask   — 1=masked (reset='1, all masked)
//   0x28  IRQSC   IRQ source config — 0=level, 1=edge
//   0x30  ISR     interrupt service register (latched)
//   0x38  RIS     raw interrupt status (unmasked)
//   0x40  IMSC    interrupt mask set/clear — 1=enabled (reset='1)
//   0x48  MIS     masked interrupt status = ISR & IMSC  (read-only)
//
// irq = |(ISR & IMSC)
module gpio #(
    parameter int unsigned N_PINS = 32
) (
    input  logic clk,
    input  logic rst_n,

    input  wb_req_t  wb_req,
    output wb_resp_t wb_resp,

    input  logic [N_PINS-1:0] gpio_in,
    output logic [N_PINS-1:0] gpio_out,
    output logic [N_PINS-1:0] gpio_oe,

    output logic irq
);

    localparam logic [7:0] REG_ID    = 8'h00;
    localparam logic [7:0] REG_DIR   = 8'h08;
    localparam logic [7:0] REG_DATA  = 8'h10;
    localparam logic [7:0] REG_IRQSS = 8'h18;
    localparam logic [7:0] REG_IRQSM = 8'h20;
    localparam logic [7:0] REG_IRQSC = 8'h28;
    localparam logic [7:0] REG_ISR   = 8'h30;
    localparam logic [7:0] REG_RIS   = 8'h38;
    localparam logic [7:0] REG_IMSC  = 8'h40;
    localparam logic [7:0] REG_MIS   = 8'h48;

    logic [N_PINS-1:0] dir_r;
    logic [N_PINS-1:0] out_r;
    logic [N_PINS-1:0] irqss_r;
    logic [N_PINS-1:0] irqsm_r;
    logic [N_PINS-1:0] irqsc_r;
    logic [N_PINS-1:0] isr_r;
    logic [N_PINS-1:0] imsc_r;

    // 2-FF input synchroniser
    logic [N_PINS-1:0] in_s0, in_s1, in_prev;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_s0   <= '0;
            in_s1   <= '0;
            in_prev <= '0;
        end else begin
            in_s0   <= gpio_in;
            in_s1   <= in_s0;
            in_prev <= in_s1;
        end
    end

    // Interrupt source: level or edge depending on IRQSC
    logic [N_PINS-1:0] edge_pulse;
    logic [N_PINS-1:0] irq_source;

    assign edge_pulse = in_s1 & ~in_prev;                                  // rising edge
    assign irq_source = (irqsc_r & edge_pulse) | (~irqsc_r & in_s1);      // edge or level

    // W1C mask from bus write (combinational, used only during write cycle)
    logic do_irqss_w1c;
    logic [N_PINS-1:0] w1c_mask;

    assign do_irqss_w1c = wb_req.cyc && wb_req.stb && wb_req.we
                          && (wb_req.adr[7:0] == REG_IRQSS);
    assign w1c_mask     = do_irqss_w1c ? wb_req.dat[N_PINS-1:0] : '0;

    // IRQSS: set from irq_source, cleared by W1C write — merged in one expression
    // @Note: previous version split this into two always_ff blocks causing a race.
    //        Both updates are now merged: new = (old | source) & ~w1c
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            irqss_r <= '0;
        else
            irqss_r <= (irqss_r | irq_source) & ~w1c_mask;
    end

    // ISR: combinationally derived — no separate register needed
    // Registered one cycle after irqss_r to prevent combinational path to irq output
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) isr_r <= '0;
        else        isr_r <= irqss_r & ~irqsm_r;
    end

    // Configuration registers
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dir_r   <= '0;
            out_r   <= '0;
            irqsm_r <= '1;  // all masked at reset
            irqsc_r <= '0;  // level-triggered by default
            imsc_r  <= '1;  // all interrupt outputs enabled
        end else if (wb_req.cyc && wb_req.stb && wb_req.we) begin
            unique case (wb_req.adr[7:0])
                REG_DIR:   dir_r   <= wb_req.dat[N_PINS-1:0];
                REG_DATA:  out_r   <= wb_req.dat[N_PINS-1:0];
                REG_IRQSM: irqsm_r <= wb_req.dat[N_PINS-1:0];
                REG_IRQSC: irqsc_r <= wb_req.dat[N_PINS-1:0];
                REG_IMSC:  imsc_r  <= wb_req.dat[N_PINS-1:0];
                default:   begin end
            endcase
        end
    end

    // Read mux — combinational, result valid same cycle as request
    always_comb begin
        wb_resp = WB_RESP_IDLE;
        if (wb_req.cyc && wb_req.stb) begin
            wb_resp.ack = 1'b1;
            if (!wb_req.we) begin
                unique case (wb_req.adr[7:0])
                    REG_ID:    wb_resp.dat = {{(XLEN-1){1'b0}}, 1'b1};
                    REG_DIR:   wb_resp.dat = {{(XLEN-N_PINS){1'b0}}, dir_r};
                    REG_DATA:  wb_resp.dat = {{(XLEN-N_PINS){1'b0}},
                                              (in_s1 & ~dir_r) | (out_r & dir_r)};
                    REG_IRQSS: wb_resp.dat = {{(XLEN-N_PINS){1'b0}}, irqss_r};
                    REG_IRQSM: wb_resp.dat = {{(XLEN-N_PINS){1'b0}}, irqsm_r};
                    REG_IRQSC: wb_resp.dat = {{(XLEN-N_PINS){1'b0}}, irqsc_r};
                    REG_ISR:   wb_resp.dat = {{(XLEN-N_PINS){1'b0}}, isr_r};
                    REG_RIS:   wb_resp.dat = {{(XLEN-N_PINS){1'b0}}, irq_source};
                    REG_IMSC:  wb_resp.dat = {{(XLEN-N_PINS){1'b0}}, imsc_r};
                    REG_MIS:   wb_resp.dat = {{(XLEN-N_PINS){1'b0}}, isr_r & imsc_r};
                    default:   wb_resp.err = 1'b1;
                endcase
            end
        end
    end

    assign gpio_out = out_r;
    assign gpio_oe  = dir_r;
    assign irq      = |(isr_r & imsc_r);

endmodule

`endif
