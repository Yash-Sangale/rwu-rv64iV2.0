// Clock control unit — Wishbone B4 Classic slave.
// Ported from professor's asCguCore/asCguTop, as_pack dependency removed.
//
// Generates divided clocks from the input clock:
//   clk_core  — CPU core clock (div_core parameter)
//   clk_bus   — peripheral bus clock
//   clk_qspi  — QSPI interface clock
//
// Register map (byte offsets from CLK_CTL_BASE):
//   0x00  ID        read-only, reset=0x10
//   0x08  DIV_CORE  [7:0] core clock divisor  (default=CLK_CORE_DIV)
//   0x10  DIV_BUS   [7:0] bus  clock divisor  (default=CLK_BUS_DIV)
//   0x18  DIV_QSPI  [7:0] qspi clock divisor  (default=CLK_QSPI_DIV)
//
// @Note clk_core/bus/qspi are derived clocks — they should be treated as
//   gated/divided signals and must be registered properly at destination.
//   For FPGA, consider using BUFGCE or MMCM instead of this divider for
//   timing-critical clocks. This module is primarily for simulation realism.

`timescale 1ns/1ps

`ifndef CLK_CTL_SV
`define CLK_CTL_SV

`include "isa_pkg.sv"
`include "wb_pkg.sv"

import isa_pkg::*;
import wb_pkg::*;


module clk_ctrl #(
    parameter int unsigned CLK_CORE_DIV = 1,   // 1 = pass-through (80 MHz → 80 MHz)
    parameter int unsigned CLK_BUS_DIV  = 1,
    parameter int unsigned CLK_QSPI_DIV = 4    // 80 MHz → 20 MHz
) (
    input  logic clk,      // system clock (from PLL / board oscillator)
    input  logic rst_n,

    input  wb_req_t  wb_req,
    output wb_resp_t wb_resp,

    output logic clk_core,
    output logic clk_bus,
    output logic clk_qspi
);

    localparam logic [7:0] REG_ID       = 8'h00;
    localparam logic [7:0] REG_DIV_CORE = 8'h08;
    localparam logic [7:0] REG_DIV_BUS  = 8'h10;
    localparam logic [7:0] REG_DIV_QSPI = 8'h18;

    logic [7:0] div_core_r, div_bus_r, div_qspi_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_core_r <= 8'(CLK_CORE_DIV);
            div_bus_r  <= 8'(CLK_BUS_DIV);
            div_qspi_r <= 8'(CLK_QSPI_DIV);
        end else if (wb_req.cyc && wb_req.stb && wb_req.we) begin
            unique case (wb_req.adr[7:0])
                REG_DIV_CORE: div_core_r <= wb_req.dat[7:0];
                REG_DIV_BUS:  div_bus_r  <= wb_req.dat[7:0];
                REG_DIV_QSPI: div_qspi_r <= wb_req.dat[7:0];
                default: begin end
            endcase
        end
    end

    always_comb begin
        wb_resp = WB_RESP_IDLE;
        if (wb_req.cyc && wb_req.stb) begin
            wb_resp.ack = 1'b1;
            if (!wb_req.we) begin
                unique case (wb_req.adr[7:0])
                    REG_ID:       wb_resp.dat = 64'h10;
                    REG_DIV_CORE: wb_resp.dat = {56'b0, div_core_r};
                    REG_DIV_BUS:  wb_resp.dat = {56'b0, div_bus_r};
                    REG_DIV_QSPI: wb_resp.dat = {56'b0, div_qspi_r};
                    default:      wb_resp.err = 1'b1;
                endcase
            end
        end
    end

    // Clock dividers — counter-based, produces 50% duty-cycle output
    // Ported directly from asCguCore.sv
    int cnt_core, cnt_bus, cnt_qspi;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) cnt_core <= 0;
        else if (cnt_core >= int'(div_core_r) - 1) cnt_core <= 0;
        else cnt_core <= cnt_core + 1;
    end
    assign clk_core = (cnt_core < int'(div_core_r) / 2) ? 1'b1 : 1'b0;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) cnt_bus <= 0;
        else if (cnt_bus >= int'(div_bus_r) - 1) cnt_bus <= 0;
        else cnt_bus <= cnt_bus + 1;
    end
    assign clk_bus = (cnt_bus < int'(div_bus_r) / 2) ? 1'b1 : 1'b0;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) cnt_qspi <= 0;
        else if (cnt_qspi >= int'(div_qspi_r) - 1) cnt_qspi <= 0;
        else cnt_qspi <= cnt_qspi + 1;
    end
    assign clk_qspi = (cnt_qspi < int'(div_qspi_r) / 2) ? 1'b1 : 1'b0;

endmodule

`endif
