`timescale 1ns / 1ps

`ifndef WB_INTERCON_SV
`define WB_INTERCON_SV

`include "isa_pkg.sv"
`include "wb_pkg.sv"
`include "mem_map_pkg.sv"

import isa_pkg::*;
import wb_pkg::*;
import mem_map_pkg::*;

// Single-master address decoder / fanout.
// DMEM is Harvard — not a slave here.
// Unmapped access: ack=1 err=1 (one-cycle error response).
module wb_intercon (
    input  logic     clk,
    input  logic     rst_n,

    input  wb_req_t  m_req,
    output wb_resp_t m_resp,

    output wb_req_t  uart_req,
    input  wb_resp_t uart_resp,

    output wb_req_t  gpio_req,
    input  wb_resp_t gpio_resp,

    output wb_req_t  qspi0_req,
    input  wb_resp_t qspi0_resp,

    output wb_req_t  irq_req,
    input  wb_resp_t irq_resp,

    output wb_req_t  clk_req,
    input  wb_resp_t clk_resp,

    output wb_req_t  jtag_req,
    input  wb_resp_t jtag_resp
);

    // @Note slave_sel was missing in previous version — caused compile error
    wb_slave_sel_t slave_sel;

    always_comb begin
        slave_sel = WB_SLAVE_NONE;
        if (m_req.cyc && m_req.stb) begin
            if      (in_uart0(m_req.adr))   slave_sel = WB_SLAVE_UART;
            else if (in_gpio0(m_req.adr))   slave_sel = WB_SLAVE_GPIO;
            else if (in_qspi0(m_req.adr))   slave_sel = WB_SLAVE_QSPI;
            else if (in_irq_ctl(m_req.adr)) slave_sel = WB_SLAVE_IRQ;
            else if (in_clk_ctl(m_req.adr)) slave_sel = WB_SLAVE_CLK;
            else if (in_jtag(m_req.adr))    slave_sel = WB_SLAVE_JTAG;
        end
    end

    always_comb begin
        uart_req  = WB_REQ_IDLE;
        gpio_req  = WB_REQ_IDLE;
        qspi0_req = WB_REQ_IDLE;
        irq_req   = WB_REQ_IDLE;
        clk_req   = WB_REQ_IDLE;
        jtag_req  = WB_REQ_IDLE;

        unique case (slave_sel)
            WB_SLAVE_UART: begin
                uart_req     = m_req;
                uart_req.adr = m_req.adr - UART0_BASE;
            end
            WB_SLAVE_GPIO: begin
                gpio_req     = m_req;
                gpio_req.adr = m_req.adr - GPIO0_BASE;
            end
            WB_SLAVE_QSPI: begin
                qspi0_req     = m_req;
                qspi0_req.adr = m_req.adr - QSPI0_BASE;
            end
            WB_SLAVE_IRQ: begin
                irq_req     = m_req;
                irq_req.adr = m_req.adr - IRQ_CTL_BASE;
            end
            WB_SLAVE_CLK: begin
                clk_req     = m_req;
                clk_req.adr = m_req.adr - CLK_CTL_BASE;
            end
            WB_SLAVE_JTAG: begin
                jtag_req     = m_req;
                jtag_req.adr = m_req.adr - JTAG_BASE;
            end
            default: begin end
        endcase
    end

    always_comb begin
        m_resp = WB_RESP_IDLE;
        unique case (slave_sel)
            WB_SLAVE_UART: m_resp = uart_resp;
            WB_SLAVE_GPIO: m_resp = gpio_resp;
            WB_SLAVE_QSPI: m_resp = qspi0_resp;
            WB_SLAVE_IRQ:  m_resp = irq_resp;
            WB_SLAVE_CLK:  m_resp = clk_resp;
            WB_SLAVE_JTAG: m_resp = jtag_resp;
            default: begin
                if (m_req.cyc && m_req.stb) begin
                    m_resp.ack = 1'b1;
                    m_resp.err = 1'b1;
                end
            end
        endcase
    end

endmodule

`endif
