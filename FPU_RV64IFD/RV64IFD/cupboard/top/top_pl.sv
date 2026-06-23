`timescale 1ns/1ps

`ifndef TOP_PL_SV
`define TOP_PL_SV

`include "isa_pkg.sv"
`include "types_pkg.sv"
`include "wb_pkg.sv"
`include "mem_map_pkg.sv"

`include "if_stage.sv"
`include "id_stage.sv"
`include "ex_stage.sv"
`include "mem_stage.sv"
`include "wb_stage.sv"
`include "hazard_unit.sv"

`include "i_regfile.sv"
`include "f_regfile.sv"
`include "csr_regfile.sv"
`include "trap_ctrl.sv"

`include "i_mem.sv"
`include "d_mem.sv"
`include "wb_intercon.sv"
`include "uart0.sv"
`include "gpio.sv"
`include "irq_ctl.sv"
`include "clk_ctl.sv"

import isa_pkg::*;
import types_pkg::*;
import wb_pkg::*;
import mem_map_pkg::*;

// Pipelined RV64IMFD SoC.
//
// Pipeline: IF → ID → EX → MEM → WB (5-stage, fully interlocked)
// Hazards:  load-use (1-cycle stall), memory stall (hold), branch/jump (2-cycle flush)
// Traps:    illegal instr, address misaligned, external interrupt (via irq_ctl)
// FPU:      full RV64FD — arithmetic, compare, convert, sign-injection,
//           min/max, move, classify, fmt-conversion, FLD/FSD/FLW/FSW
// CSR:      mstatus/mie/mtvec/mepc/mcause/mip + fflags/frm/fcsr
//
// Harvard I-Bus: CPU → i_mem (direct, 64 KB)
// D-Bus:         CPU → d_mem (direct, 64 KB) | wb_intercon → peripherals
module top_pl #(
    parameter string IMEM_INIT_FILE = "",
    parameter string DMEM_INIT_FILE = "",
    parameter int    CLK_FREQ_HZ    = 80_000_000,
    parameter int    BAUD_RATE      = 115_200
) (
    input  logic       clk,
    input  logic       rst_n,

    output logic       uart_tx,
    input  logic       uart_rx,

    inout  tri [31:0]  gpio_io,

    output logic       cs_o     // GPIO chip-select — testbench monitor hook
);

  // =========================================================================
  // Pipeline inter-stage registers
  // =========================================================================
  if_id_reg_t  if_id_r,  if_id_next;
  id_ex_reg_t  id_ex_r,  id_ex_next;
  ex_mem_reg_t ex_mem_r, ex_mem_next;
  mem_wb_reg_t mem_wb_r, mem_wb_next;

  // =========================================================================
  // Hazard / redirect signals
  // =========================================================================
  logic if_stall, id_stall, ex_stall, mem_stall_hz;
  logic if_flush, id_flush;
  logic mem_stall_raw;

  logic        redirect_valid;
  logic [63:0] redirect_pc;

  logic        branch_taken_ex;
  logic [63:0] branch_target_ex;

  // CSR outputs
  logic [63:0] mtvec, mepc;
  logic        mie_global, irq_pending;
  logic [2:0]  frm_csr;

  // Trap / MRET pulses
  logic        trap_taken, mret_taken;
  logic [63:0] trap_cause_v, trap_pc_v;

  logic global_flush;
  assign global_flush = trap_taken || mret_taken;

  // PC redirect priority: trap > mret > branch/jump
  always_comb begin
    if (trap_taken) begin
      redirect_valid = 1'b1;
      redirect_pc    = {mtvec[63:2], 2'b00};
    end else if (mret_taken) begin
      redirect_valid = 1'b1;
      redirect_pc    = mepc;
    end else if (branch_taken_ex) begin
      redirect_valid = 1'b1;
      redirect_pc    = branch_target_ex;
    end else begin
      redirect_valid = 1'b0;
      redirect_pc    = '0;
    end
  end

  // =========================================================================
  // Hazard Unit
  // =========================================================================
  hazard_unit u_hazard (
      .id_ex_valid  (id_ex_r.valid),
      .ex_mem_valid (ex_mem_r.valid),
      .id_rs1       (if_id_r.instr[19:15]),
      .id_rs2       (if_id_r.instr[24:20]),
      .ex_rd        (id_ex_r.dec.rd),
      .ex_mem_read  (id_ex_r.dec.mem_read),
      .mem_rd       (ex_mem_r.dec.rd),
      .is_fp        (id_ex_r.dec.is_fp),
      .mem_stall    (mem_stall_raw),
      .branch_taken (branch_taken_ex),
      .is_jal       (id_ex_r.dec.jal),
      .is_jalr      (id_ex_r.dec.jalr),
      .if_stall     (if_stall),
      .id_stall     (id_stall),
      .ex_stall     (ex_stall),
      .mem_stall_o  (mem_stall_hz),
      .if_flush     (if_flush),
      .id_flush     (id_flush)
  );

  // =========================================================================
  // Instruction Memory
  // =========================================================================
  logic        imem_cs;
  logic [63:0] imem_addr;
  logic [31:0] imem_rdata;
  logic        imem_valid;

  i_mem #(.INIT_FILE(IMEM_INIT_FILE), .PARITY_EN(1)) u_imem (
      .clk(clk), .rst_n(rst_n),
      .cs(imem_cs), .addr(imem_addr),
      .rdata(imem_rdata), .valid(imem_valid), .parity_err(),
      .jtag_we(1'b0), .jtag_addr('0), .jtag_wdata('0)
  );

  // =========================================================================
  // IF Stage
  // =========================================================================
  if_stage u_if (
      .clk(clk), .rst_n(rst_n),
      .stall          (if_stall),
      .flush          (if_flush || global_flush),
      .redirect_pc    (redirect_pc),
      .redirect_valid (redirect_valid),
      .imem_cs        (imem_cs),
      .imem_addr      (imem_addr),
      .imem_rdata     (imem_rdata),
      .imem_valid     (imem_valid),
      .if_id_next     (if_id_next)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                           if_id_r <= '0;
    else if (if_flush || global_flush)    if_id_r <= '0;
    else if (!if_stall)                   if_id_r <= if_id_next;
  end

  // =========================================================================
  // Register Files
  // =========================================================================
  logic [4:0]  rs1_addr_id, rs2_addr_id;
  logic [63:0] int_rs1_data, int_rs2_data;
  logic [63:0] fp_rs1_data,  fp_rs2_data;

  logic        rf_we;    logic [4:0]  rf_waddr;  logic [63:0] rf_wdata;
  logic        frf_we;   logic [4:0]  frf_waddr; logic [63:0] frf_wdata;

  i_regfile u_irf (
      .clk(clk), .rst_n(rst_n),
      .rs1_addr(rs1_addr_id), .rs1_data(int_rs1_data),
      .rs2_addr(rs2_addr_id), .rs2_data(int_rs2_data),
      .rd_addr(rf_waddr), .rd_data(rf_wdata), .rd_we(rf_we)
  );

  f_regfile u_frf (
      .clk(clk), .rst_n(rst_n),
      .rs1_addr(rs1_addr_id), .rs1_data(fp_rs1_data),
      .rs2_addr(rs2_addr_id), .rs2_data(fp_rs2_data),
      .rd_addr(frf_waddr), .rd_data(frf_wdata), .rd_we(frf_we)
  );

  // =========================================================================
  // ID Stage
  // =========================================================================
  id_stage u_id (
      .clk(clk), .rst_n(rst_n),
      .if_id(if_id_r),
      .rs1_addr(rs1_addr_id), .rs2_addr(rs2_addr_id),
      .int_rs1_data(int_rs1_data), .int_rs2_data(int_rs2_data),
      .fp_rs1_data(fp_rs1_data),   .fp_rs2_data(fp_rs2_data),
      .id_ex_next(id_ex_next)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                         id_ex_r <= '0;
    else if (id_flush || global_flush)  id_ex_r <= '0;
    else if (!id_stall)                 id_ex_r <= id_ex_next;
  end

  // =========================================================================
  // EX Stage
  // =========================================================================
  ex_stage u_ex (
      .clk(clk), .rst_n(rst_n),
      .id_ex(id_ex_r),
      .ex_mem_next(ex_mem_next)
  );

  assign branch_taken_ex  = ex_mem_next.branch_taken && id_ex_r.valid;
  assign branch_target_ex = ex_mem_next.branch_target;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)          ex_mem_r <= '0;
    else if (!ex_stall)  ex_mem_r <= ex_mem_next;
  end

  // =========================================================================
  // D-MEM and WB Interconnect wires
  // =========================================================================
  logic            dmem_cs_s, dmem_we_s;
  logic [63:0]     dmem_addr_s, dmem_wdata_s, dmem_rdata_s;
  logic [7:0]      dmem_sel_s;
  logic            dmem_ack_s;

  wb_req_t  dbus_req;
  wb_resp_t dbus_resp;

  wb_req_t  uart_req, gpio_req, qspi_req, irq_req, clk_req, jtag_req;
  wb_resp_t uart_resp, gpio_resp, qspi_resp, irq_resp, clk_resp, jtag_resp;

  assign qspi_resp = WB_RESP_IDLE;  // @Todo QSPI
  assign jtag_resp = WB_RESP_IDLE;  // @Todo JTAG

  // =========================================================================
  // MEM Stage
  // =========================================================================
  mem_stage u_mem (
      .clk(clk), .rst_n(rst_n),
      .ex_mem(ex_mem_r),
      .mem_wb_next(mem_wb_next),
      .stall(mem_stall_raw),
      .dmem_cs(dmem_cs_s), .dmem_we(dmem_we_s),
      .dmem_addr(dmem_addr_s), .dmem_sel(dmem_sel_s),
      .dmem_wdata(dmem_wdata_s),
      .dmem_rdata(dmem_rdata_s), .dmem_ack(dmem_ack_s),
      .wb_req(dbus_req), .wb_resp(dbus_resp)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)              mem_wb_r <= '0;
    else if (!mem_stall_hz)  mem_wb_r <= mem_wb_next;
  end

  // =========================================================================
  // WB Stage
  // =========================================================================
  logic [4:0] fp_fflags_wb;
  logic       fp_commit_wb;

  wb_stage u_wb (
      .clk(clk), .rst_n(rst_n),
      .mem_wb(mem_wb_r),
      .rf_we(rf_we), .rf_waddr(rf_waddr), .rf_wdata(rf_wdata),
      .frf_we(frf_we), .frf_waddr(frf_waddr), .frf_wdata(frf_wdata),
      .fp_fflags_out(fp_fflags_wb),
      .fp_commit(fp_commit_wb)
  );

  // =========================================================================
  // CSR + Trap
  // =========================================================================
  logic is_csr_wb, is_mret_wb;
  assign is_csr_wb  = mem_wb_r.valid
                      && (mem_wb_r.dec.opcode == OP_SYSTEM)
                      && (mem_wb_r.dec.funct3 != 3'b000);
  assign is_mret_wb = mem_wb_r.valid
                      && (mem_wb_r.dec.opcode == OP_SYSTEM)
                      && (mem_wb_r.dec.funct3 == 3'b000)
                      && (mem_wb_r.dec.imm[11:0] == 12'h302);

  logic irq_to_core;

  csr_regfile u_csr (
      .clk(clk), .rst_n(rst_n),
      .csr_en      (is_csr_wb),
      .csr_addr    (mem_wb_r.dec.imm[11:0]),
      .csr_funct3  (mem_wb_r.dec.funct3),
      .csr_rs1_val (mem_wb_r.wb_data),
      .csr_uimm    (mem_wb_r.dec.rs1),
      .csr_rdata   (),                 // @Note CSR read data goes to WB result mux — @Todo connect
      .trap_taken  (trap_taken),
      .trap_pc     (trap_pc_v),
      .trap_cause  (trap_cause_v),
      .mret        (mret_taken),
      .irq_ext     (irq_to_core),
      .fp_fflags_in(fp_fflags_wb),
      .fp_commit   (fp_commit_wb),
      .mtvec_o     (mtvec),
      .mepc_o      (mepc),
      .mie_global  (mie_global),
      .irq_pending (irq_pending),
      .frm_o       (frm_csr)
  );

  logic instr_commit_wb;
  assign instr_commit_wb = mem_wb_r.valid && !trap_taken;

  trap_ctrl u_trap (
      .clk(clk), .rst_n(rst_n),
      .instr_commit         (instr_commit_wb),
      .commit_pc            (mem_wb_r.alu_fpu_result),
      .commit_pc_plus4      (mem_wb_r.alu_fpu_result + 64'd4),
      .commit_opcode        (mem_wb_r.dec.opcode),
      .commit_funct3        (mem_wb_r.dec.funct3),
      .commit_branch_taken  (mem_wb_r.dec.branch || mem_wb_r.dec.jal || mem_wb_r.dec.jalr),
      .commit_branch_target (mem_wb_r.alu_fpu_result),
      .commit_addr_misaligned(mem_wb_r.addr_misaligned),
      .illegal_instr        (1'b0),   // @Note: illegal already filtered in ID (valid=0)
      .is_mret              (is_mret_wb),
      .irq_pending          (irq_pending),
      .trap_taken           (trap_taken),
      .trap_cause           (trap_cause_v),
      .trap_pc              (trap_pc_v),
      .mret_taken           (mret_taken)
  );

  // =========================================================================
  // Data Memory
  // =========================================================================
  d_mem #(.INIT_FILE(DMEM_INIT_FILE), .FWD_EN(1), .PARITY_EN(1)) u_dmem (
      .clk(clk), .rst_n(rst_n),
      .cs(dmem_cs_s), .we(dmem_we_s),
      .addr(dmem_addr_s), .sel(dmem_sel_s),
      .wdata(dmem_wdata_s), .rdata(dmem_rdata_s),
      .ack(dmem_ack_s), .parity_err(),
      .dbg_addr('0), .dbg_rdata()
  );

  // =========================================================================
  // Wishbone Interconnect
  // =========================================================================
  wb_intercon u_intercon (
      .clk(clk), .rst_n(rst_n),
      .m_req(dbus_req), .m_resp(dbus_resp),
      .uart_req(uart_req),   .uart_resp(uart_resp),
      .gpio_req(gpio_req),   .gpio_resp(gpio_resp),
      .qspi0_req(qspi_req),  .qspi0_resp(qspi_resp),
      .irq_req(irq_req),     .irq_resp(irq_resp),
      .clk_req(clk_req),     .clk_resp(clk_resp),
      .jtag_req(jtag_req),   .jtag_resp(jtag_resp)
  );

  // =========================================================================
  // Peripherals
  // =========================================================================
  uart0 #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .BAUD_RATE(BAUD_RATE)) u_uart (
      .clk(clk), .rst_n(rst_n),
      .wb_req(uart_req), .wb_resp(uart_resp),
      .tx(uart_tx), .rx(uart_rx), .irq()
  );

  logic [31:0] gpio_in_s, gpio_out_s, gpio_oe_s;
  logic        irq_gpio;

  genvar gi;
  generate
    for (gi = 0; gi < 32; gi++) begin : gpio_pad
      assign gpio_io[gi]  = gpio_oe_s[gi] ? gpio_out_s[gi] : 1'bz;
      assign gpio_in_s[gi] = gpio_io[gi];
    end
  endgenerate

  gpio u_gpio (
      .clk(clk), .rst_n(rst_n),
      .wb_req(gpio_req), .wb_resp(gpio_resp),
      .gpio_in(gpio_in_s), .gpio_out(gpio_out_s), .gpio_oe(gpio_oe_s),
      .irq(irq_gpio)
  );

  assign cs_o = gpio_req.cyc && gpio_req.stb;

  logic [7:0] irq_src_s;
  assign irq_src_s = {7'b0, irq_gpio};

  irq_ctl #(.N_IRQ(8)) u_irqctl (
      .clk(clk), .rst_n(rst_n),
      .wb_req(irq_req), .wb_resp(irq_resp),
      .irq_src(irq_src_s),
      .irq_out(irq_to_core),
      .irq_vec()
  );

  clk_ctl u_clkctl (
      .clk(clk), .rst_n(rst_n),
      .wb_req(clk_req), .wb_resp(clk_resp),
      .clk_core(), .clk_bus(), .clk_qspi()
  );

endmodule

`endif
