// =============================================================================
// regfile.sv — RV64I Integer Register File
// 32 × 64-bit registers. x0 is hardwired to zero.
// Synchronous write, Synchronous  read.
// Two independent read ports, one write port.
// =============================================================================

`ifndef I_REGFILE_SV
`define I_REGFILE_SV 

`timescale 1ns / 1ps

`include "types_pkg.sv"
`include "isa_pkg.sv"

import isa_pkg::*;
import types_pkg::*;

module i_regfile #(
    parameter bit ASYNC_READ = 1'b1
) (
    input  logic                       clk,
    input  logic                       rst_n,
    // Read port A (rs1)
    input  logic [REG_ADDRESS_LEN-1:0] rs1_addr,
    output logic [           XLEN-1:0] rs1_data,
    // Read port B (rs2)
    input  logic [REG_ADDRESS_LEN-1:0] rs2_addr,
    output logic [           XLEN-1:0] rs2_data,
    // Write port (rd)
    input  logic [REG_ADDRESS_LEN-1:0] rd_addr,
    input  logic [           XLEN-1:0] rd_data,
    input  logic                       rd_we      // write enable
);

  logic [63:0] regs[0:REG_COUNT-1];

  // Synchronous write — x0 cannot be written
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < REG_COUNT; i++) begin
        regs[i] <= '0;
      end
    end else if (rd_we && rd_addr != '0) begin
      regs[rd_addr] <= rd_data;
    end
  end

  generate

    if (ASYNC_READ) begin : g_async_read

      assign rs1_data = (rs1_addr == '0) ? '0 : regs[rs1_addr];
      assign rs2_data = (rs2_addr == '0) ? '0 : regs[rs2_addr];

    end else begin : g_sync_read

      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          rs1_data <= '0;
          rs2_data <= '0;
        end else begin
          rs1_data <= (rs1_addr == '0) ? '0 : regs[rs1_addr];
          rs2_data <= (rs2_addr == '0) ? '0 : regs[rs2_addr];
        end
      end

    end

  endgenerate

endmodule

`endif  //I_REGFILE_SV
