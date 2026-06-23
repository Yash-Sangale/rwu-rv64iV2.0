`timescale 1ns/1ps

`ifndef UART0_SV
`define UART0_SV

`include "isa_pkg.sv"
`include "wb_pkg.sv"

import isa_pkg::*;
import wb_pkg::*;

// UART0 — 8N1, Wishbone B4 Classic slave.
//
// Register map (byte offsets from UART0_BASE):
//   0x00  CTRL    [0]=TX_EN [1]=RX_EN [2]=INT_EN
//   0x08  STATUS  [0]=TX_BUSY [1]=RX_READY
//   0x10  TXDATA  [7:0] write triggers TX
//   0x18  RXDATA  [7:0] read clears RX_READY
//   0x20  BAUD    [15:0] oversampling divisor (clk / (baud*16))
//
// TX/RX cores are FSM-based (ported from professor's as_tx/as_rx/as_br).
// Baud generator: 16x oversampling tick, restartable on RX start-bit.
module uart0 #(
    parameter int unsigned CLK_FREQ_HZ = 80_000_000,
    parameter int unsigned BAUD_RATE   = 115_200
) (
    input  logic clk,
    input  logic rst_n,

    input  wb_req_t  wb_req,
    output wb_resp_t wb_resp,

    output logic tx,
    input  logic rx,
    output logic irq
);

    localparam logic [7:0] REG_CTRL   = 8'h00;
    localparam logic [7:0] REG_STATUS = 8'h08;
    localparam logic [7:0] REG_TXDATA = 8'h10;
    localparam logic [7:0] REG_RXDATA = 8'h18;
    localparam logic [7:0] REG_BAUD   = 8'h20;

    // Default divisor: clk / (baud * 16)
    localparam int BR_DIV_DEFAULT = CLK_FREQ_HZ / (BAUD_RATE * 16);

    logic        tx_en, rx_en, int_en;
    logic [15:0] baud_div;
    logic        tx_busy, rx_ready;
    logic [7:0]  tx_data_r, rx_data_r;

    // -------------------------------------------------------------------------
    // Baud generator — 16x oversampling tick
    // Restartable: rx_start resets counter to align sampling to start-bit edge
    // -------------------------------------------------------------------------
    logic [15:0] br_cnt;
    logic        br_tick;   // one pulse per bit-period/16
    logic        br2_tick;  // pulse at mid-point of bit-period
    logic        rx_start;  // from RX FSM: start-bit detected, sync baud counter

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            br_cnt  <= '0;
            br_tick <= 1'b0;
        end else begin
            br_tick <= 1'b0;
            if (rx_start || br_cnt == baud_div - 1) begin
                br_cnt  <= '0;
                br_tick <= !rx_start;  // don't emit tick on reset-cycle
            end else begin
                br_cnt <= br_cnt + 1'b1;
            end
        end
    end

    // Mid-point tick: fires at baud_div/2 — used by RX to sample data
    logic [15:0] br2_ref;
    assign br2_ref  = baud_div >> 1;
    assign br2_tick = (br_cnt == br2_ref);

    // -------------------------------------------------------------------------
    // TX FSM (from professor's as_tx)
    // States: IDLE → WAIT → START → B0..B7 → STOP
    // -------------------------------------------------------------------------
    typedef enum logic [3:0] {
        TX_IDLE, TX_WAIT, TX_START,
        TX_B0, TX_B1, TX_B2, TX_B3,
        TX_B4, TX_B5, TX_B6, TX_B7,
        TX_STOP
    } tx_state_t;

    tx_state_t tx_st, tx_st_next;
    logic [7:0] tx_shift;

    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) tx_st <= TX_IDLE;
        else        tx_st <= tx_st_next;

    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n)           tx_shift <= '0;
        else if (tx_st == TX_IDLE && tx_busy)
                              tx_shift <= tx_data_r;

    always_comb begin
        tx_st_next = tx_st;
        unique case (tx_st)
            TX_IDLE:  if (tx_busy)    tx_st_next = TX_WAIT;
            TX_WAIT:  if (br_tick)    tx_st_next = TX_START;
            TX_START: if (br_tick)    tx_st_next = TX_B0;
            TX_B0:    if (br_tick)    tx_st_next = TX_B1;
            TX_B1:    if (br_tick)    tx_st_next = TX_B2;
            TX_B2:    if (br_tick)    tx_st_next = TX_B3;
            TX_B3:    if (br_tick)    tx_st_next = TX_B4;
            TX_B4:    if (br_tick)    tx_st_next = TX_B5;
            TX_B5:    if (br_tick)    tx_st_next = TX_B6;
            TX_B6:    if (br_tick)    tx_st_next = TX_B7;
            TX_B7:    if (br_tick)    tx_st_next = TX_STOP;
            TX_STOP:  if (br_tick)    tx_st_next = TX_IDLE;
            default:                  tx_st_next = TX_IDLE;
        endcase
    end

    // tx_busy: set by register write, cleared when TX_STOP finishes
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            tx_busy <= 1'b0;
        else if (tx_en && wb_req.cyc && wb_req.stb && wb_req.we
                 && wb_req.adr[7:0] == REG_TXDATA && !tx_busy)
            tx_busy <= 1'b1;
        else if (tx_st == TX_STOP && br_tick)
            tx_busy <= 1'b0;
    end

    always_comb begin
        case (tx_st)
            TX_IDLE, TX_WAIT, TX_STOP: tx = 1'b1;
            TX_START:                  tx = 1'b0;
            TX_B0:                     tx = tx_shift[0];
            TX_B1:                     tx = tx_shift[1];
            TX_B2:                     tx = tx_shift[2];
            TX_B3:                     tx = tx_shift[3];
            TX_B4:                     tx = tx_shift[4];
            TX_B5:                     tx = tx_shift[5];
            TX_B6:                     tx = tx_shift[6];
            TX_B7:                     tx = tx_shift[7];
            default:                   tx = 1'b1;
        endcase
    end

    // -------------------------------------------------------------------------
    // RX FSM (from professor's as_rx)
    // 2-FF synchroniser + falling-edge start-bit detector
    // -------------------------------------------------------------------------
    typedef enum logic [3:0] {
        RX_IDLE, RX_START_SYNC, RX_WAIT, RX_START,
        RX_B0, RX_B1, RX_B2, RX_B3,
        RX_B4, RX_B5, RX_B6, RX_B7,
        RX_STOP
    } rx_state_t;

    rx_state_t rx_st, rx_st_next;

    logic rx_s0, rx_s1, rx_s2;  // 2-FF + one more for edge detect
    logic rx_fall;               // falling edge on RX line
    logic [7:0] rx_shift;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin rx_s0 <= 1'b1; rx_s1 <= 1'b1; rx_s2 <= 1'b1; end
        else        begin rx_s0 <= rx; rx_s1 <= rx_s0; rx_s2 <= rx_s1; end
    end
    assign rx_fall = rx_s2 & ~rx_s1;  // falling edge

    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) rx_st <= RX_IDLE;
        else        rx_st <= rx_st_next;

    always_comb begin
        rx_st_next = rx_st;
        unique case (rx_st)
            RX_IDLE:       if (rx_fall && rx_en) rx_st_next = RX_START_SYNC;
            RX_START_SYNC:                       rx_st_next = RX_WAIT;
            RX_WAIT:       if (br_tick)          rx_st_next = RX_START;
            RX_START:      if (br_tick)          rx_st_next = RX_B0;
            RX_B0:         if (br_tick)          rx_st_next = RX_B1;
            RX_B1:         if (br_tick)          rx_st_next = RX_B2;
            RX_B2:         if (br_tick)          rx_st_next = RX_B3;
            RX_B3:         if (br_tick)          rx_st_next = RX_B4;
            RX_B4:         if (br_tick)          rx_st_next = RX_B5;
            RX_B5:         if (br_tick)          rx_st_next = RX_B6;
            RX_B6:         if (br_tick)          rx_st_next = RX_B7;
            RX_B7:         if (br_tick)          rx_st_next = RX_STOP;
            RX_STOP:       if (br_tick)          rx_st_next = RX_IDLE;
            default:                             rx_st_next = RX_IDLE;
        endcase
    end

    // rx_start pulses when start-bit sync state entered — resets baud counter
    assign rx_start = (rx_st == RX_START_SYNC);

    // Sample each data bit at mid-point (br2_tick)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) rx_shift <= '0;
        else if (br2_tick) begin
            unique case (rx_st)
                RX_B0: rx_shift[0] <= rx_s1;
                RX_B1: rx_shift[1] <= rx_s1;
                RX_B2: rx_shift[2] <= rx_s1;
                RX_B3: rx_shift[3] <= rx_s1;
                RX_B4: rx_shift[4] <= rx_s1;
                RX_B5: rx_shift[5] <= rx_s1;
                RX_B6: rx_shift[6] <= rx_s1;
                RX_B7: rx_shift[7] <= rx_s1;
                default: begin end
            endcase
        end
    end

    // rx_ready: set when stop bit sampled valid, cleared on RXDATA read
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_ready  <= 1'b0;
            rx_data_r <= '0;
        end else begin
            if (rx_st == RX_STOP && br2_tick && rx_s1) begin
                rx_data_r <= rx_shift;
                rx_ready  <= 1'b1;
            end
            if (rx_ready && wb_req.cyc && wb_req.stb && !wb_req.we
                && wb_req.adr[7:0] == REG_RXDATA)
                rx_ready <= 1'b0;
        end
    end

    // -------------------------------------------------------------------------
    // Wishbone register file
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_en    <= 1'b1;
            rx_en    <= 1'b1;
            int_en   <= 1'b0;
            baud_div <= 16'(BR_DIV_DEFAULT);
            tx_data_r <= '0;
        end else if (wb_req.cyc && wb_req.stb && wb_req.we) begin
            unique case (wb_req.adr[7:0])
                REG_CTRL:   {int_en, rx_en, tx_en} <= wb_req.dat[2:0];
                REG_TXDATA: if (tx_en && !tx_busy) tx_data_r <= wb_req.dat[7:0];
                REG_BAUD:   baud_div <= wb_req.dat[15:0];
                default:    begin end
            endcase
        end
    end

    always_comb begin
        wb_resp = WB_RESP_IDLE;
        if (wb_req.cyc && wb_req.stb) begin
            wb_resp.ack = 1'b1;
            if (!wb_req.we) begin
                unique case (wb_req.adr[7:0])
                    REG_CTRL:   wb_resp.dat = {61'b0, int_en, rx_en, tx_en};
                    REG_STATUS: wb_resp.dat = {62'b0, rx_ready, tx_busy};
                    REG_TXDATA: wb_resp.dat = {56'b0, tx_data_r};
                    REG_RXDATA: wb_resp.dat = {56'b0, rx_data_r};
                    REG_BAUD:   wb_resp.dat = {48'b0, baud_div};
                    default:    wb_resp.err = 1'b1;
                endcase
            end
        end
    end

    assign irq = int_en && rx_ready;

endmodule

`endif
