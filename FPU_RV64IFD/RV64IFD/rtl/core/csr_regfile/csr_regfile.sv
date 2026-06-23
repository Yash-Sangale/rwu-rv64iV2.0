`timescale 1ns / 1ps

`ifndef CSR_REGFILE_H
`define CSR_REGFILE_H

`include "isa_pkg.sv"

import isa_pkg::*;

// Machine-mode CSR register file — extended with FP CSRs (fflags/frm/fcsr).
//
// Trap CSRs:
//   0x300  mstatus  — MIE[3], MPIE[7], MPP[12:11], FS[14:13]
//   0x304  mie      — MEIE[11]
//   0x305  mtvec    — trap vector base
//   0x341  mepc     — exception PC
//   0x342  mcause   — trap cause
//   0x344  mip      — MEIP[11] read-only
//
// FP CSRs (RV64F/D §11.2):
//   0x001  fflags   — accrued exception flags [4:0]  {NV,DZ,OF,UF,NX}
//   0x002  frm      — rounding mode [2:0]
//   0x003  fcsr     — {frm[2:0], fflags[4:0]}  (alias of both)
//
// fflags accumulation: wb_stage pulses fp_commit with fp_fflags_in each cycle
//   a valid FP instruction commits. Hardware ORs new flags into fflags_r.
//   Software clears fflags_r by writing CSR 0x001 or 0x003.
//
// frm output: exposed as frm_o so ex_stage can substitute fp_rm==3'b111.
module csr_regfile (
    input  logic        clk,
    input  logic        rst_n,

    // CSR instruction interface
    input  logic        csr_en,
    input  logic [11:0] csr_addr,
    input  logic [2:0]  csr_funct3,
    input  logic [XLEN-1:0] csr_rs1_val,
    input  logic [4:0]  csr_uimm,
    output logic [XLEN-1:0] csr_rdata,

    // Trap / MRET
    input  logic        trap_taken,
    input  logic [XLEN-1:0] trap_pc,
    input  logic [XLEN-1:0] trap_cause,
    input  logic        mret,

    // External interrupt
    input  logic        irq_ext,

    // FP fflags accumulation (from wb_stage)
    input  logic [4:0]  fp_fflags_in,
    input  logic        fp_commit,

    // Outputs
    output logic [XLEN-1:0] mtvec_o,
    output logic [XLEN-1:0] mepc_o,
    output logic        mie_global,
    output logic        irq_pending,
    output logic [2:0]  frm_o       // current rounding mode for fp_rm==3'b111
);

  logic [XLEN-1:0] mstatus_r;
  logic [XLEN-1:0] mie_r;
  logic [XLEN-1:0] mtvec_r;
  logic [XLEN-1:0] mepc_r;
  logic [XLEN-1:0] mcause_r;
  logic [XLEN-1:0] mip_r;
  logic [4:0]  fflags_r;   // accrued FP exception flags
  logic [2:0]  frm_r;      // FP rounding mode

  logic mstatus_mie;
  logic mstatus_mpie;
  assign mstatus_mie  = mstatus_r[3];
  assign mstatus_mpie = mstatus_r[7];

  // IRQ 2-FF synchroniser
  logic irq_sync0, irq_sync1;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin irq_sync0 <= 1'b0; irq_sync1 <= 1'b0; end
    else        begin irq_sync0 <= irq_ext; irq_sync1 <= irq_sync0; end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) mip_r <= '0;
    else        mip_r[11] <= irq_sync1;
  end

  // CSR write data (shared, independent of address).
  // Read-data for CSRRS/CSRRC comes directly from storage regs (not csr_rdata)
  // to avoid a combinational loop through the read mux.
  logic [XLEN-1:0] wdata;
  logic [XLEN-1:0] src;
  logic [XLEN-1:0] rd_val;  // current value of target CSR for RMW ops

  always_comb begin
    src = csr_funct3[2] ? {59'b0, csr_uimm} : csr_rs1_val;
    // Read current value directly from storage (not via csr_rdata mux)
    unique case (csr_addr)
      12'h300: rd_val = mstatus_r;
      12'h304: rd_val = mie_r;
      12'h305: rd_val = mtvec_r;
      12'h341: rd_val = mepc_r;
      12'h342: rd_val = mcause_r;
      12'h344: rd_val = mip_r;
      12'h001: rd_val = {59'b0, fflags_r};
      12'h002: rd_val = {61'b0, frm_r};
      12'h003: rd_val = {56'b0, frm_r, fflags_r};
      default: rd_val = '0;
    endcase
    unique case (csr_funct3[1:0])
      2'b01:   wdata = src;           // CSRRW / CSRRWI
      2'b10:   wdata = rd_val | src;  // CSRRS / CSRRSI
      2'b11:   wdata = rd_val & ~src; // CSRRC / CSRRCI
      default: wdata = src;
    endcase
  end

  // CSR read mux — includes FP CSRs
  always_comb begin
    csr_rdata = '0;
    if (csr_en) begin
      unique case (csr_addr)
        12'h300: csr_rdata = mstatus_r;
        12'h304: csr_rdata = mie_r;
        12'h305: csr_rdata = mtvec_r;
        12'h341: csr_rdata = mepc_r;
        12'h342: csr_rdata = mcause_r;
        12'h344: csr_rdata = mip_r;
        12'h001: csr_rdata = {59'b0, fflags_r};          // fflags
        12'h002: csr_rdata = {61'b0, frm_r};             // frm
        12'h003: csr_rdata = {56'b0, frm_r, fflags_r};  // fcsr
        default: csr_rdata = '0;
      endcase
    end
  end

  // mstatus
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      mstatus_r <= 64'h0000_0000_0000_1808;  // MIE=1 MPIE=1 MPP=11 (matches professor)
    else begin
      if (trap_taken) begin
        mstatus_r[7] <= mstatus_mie;
        mstatus_r[3] <= 1'b0;
      end else if (mret) begin
        mstatus_r[3] <= mstatus_mpie;
        mstatus_r[7] <= 1'b1;
      end else if (csr_en && csr_addr == 12'h300)
        mstatus_r <= wdata;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) mie_r <= 64'h0000_0000_0000_0800;
    else if (csr_en && csr_addr == 12'h304) mie_r <= wdata;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) mtvec_r <= 64'h0000_0000_0000_7F00;
    else if (csr_en && csr_addr == 12'h305) mtvec_r <= wdata;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) mepc_r <= '0;
    else begin
      if (trap_taken)                       mepc_r <= trap_pc;
      else if (csr_en && csr_addr == 12'h341) mepc_r <= wdata;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) mcause_r <= '0;
    else begin
      if (trap_taken)                       mcause_r <= trap_cause;
      else if (csr_en && csr_addr == 12'h342) mcause_r <= wdata;
    end
  end

  // fflags: accumulate on fp_commit (OR new flags in); cleared by CSR write
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      fflags_r <= 5'b0;
    else begin
      // Software write takes priority; hardware accumulation happens same cycle
      if (csr_en && (csr_addr == 12'h001))
        fflags_r <= wdata[4:0];
      else if (csr_en && (csr_addr == 12'h003))
        fflags_r <= wdata[4:0];
      else if (fp_commit)
        fflags_r <= fflags_r | fp_fflags_in;
    end
  end

  // frm
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      frm_r <= 3'b000;  // RNE default
    else begin
      if (csr_en && csr_addr == 12'h002)
        frm_r <= wdata[2:0];
      else if (csr_en && csr_addr == 12'h003)
        frm_r <= wdata[7:5];
    end
  end

  assign mtvec_o    = mtvec_r;
  assign mepc_o     = mepc_r;
  assign mie_global = mstatus_mie;
  assign irq_pending = mip_r[11] && mie_r[11] && mstatus_mie;
  assign frm_o      = frm_r;

endmodule

`endif