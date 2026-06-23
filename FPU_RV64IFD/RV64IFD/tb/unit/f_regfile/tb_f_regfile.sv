// =============================================================================
// tb_f_regfile.sv — Register File Unit Testbench (RV64D)
// Tests:
//   - Reset behavior
//   - Write + read correctness
//   - x0 immutability
//   - Dual read ports
//   - Write enable behavior
//   - Read-after-write (same cycle vs next cycle)
// =============================================================================

`timescale 1ns / 1ps

import isa_pkg::*;
import types_pkg::*;

module tb_f_regfile;


  // DUT Signals

  logic clk;
  logic rst_n;

  logic [4:0] rs1_addr, rs2_addr;
  logic [63:0] rs1_data, rs2_data;

  logic [ 4:0] rd_addr;
  logic [63:0] rd_data;
  logic        rd_we;

  // DUT
  f_regfile u_dut (
      .clk(clk),
      .rst_n(rst_n),
      .rs1_addr(rs1_addr),
      .rs1_data(rs1_data),
      .rs2_addr(rs2_addr),
      .rs2_data(rs2_data),
      .rd_addr(rd_addr),
      .rd_data(rd_data),
      .rd_we(rd_we)
  );


  // Clock Generation
  initial clk = 0;
  always #5 clk = ~clk;  // 80 MHz


  // Test infra
  int pass_count = 0;
  int fail_count = 0;
  int test_num = 0;

  int fd;
  string result_file;

  // Helpers
  task automatic check(input logic [63:0] got, input logic [63:0] expected, input string name);
    test_num++;
    if (got === expected) begin
      pass_count++;
      $display("[PASS] #%0d %-20s got=%h", test_num, name, got);
    end else begin
      fail_count++;
      $display("[FAIL] #%0d %-20s exp=%h got=%h", test_num, name, expected, got);
    end
  endtask

  // Write helper (synchronous)
  task automatic write_reg(input [4:0] addr, input [63:0] data);
    @(posedge clk);
    rd_addr = addr;
    rd_data = data;
    rd_we   = 1;
    @(posedge clk);
    rd_we = 0;
  endtask

  task automatic read_rs1(input [4:0] addr, input [63:0] expected, input string name);
    rs1_addr = addr;
    @(posedge clk);
    check(rs1_data, expected, name);
  endtask

  task automatic read_rs2(input [4:0] addr, input [63:0] expected, input string name);
    rs2_addr = addr;
    @(posedge clk);
    check(rs2_data, expected, name);
  endtask


  // Waveform
`ifdef ENABLE_WAVE
  initial begin
    if ($test$plusargs("WAVE")) begin
      $display("[WAVE] Enabled");
      $wdbDumpvars(0, tb_regfile);
    end
  end
`endif


  // TEST SEQUENCE
  initial begin

    // Result file
    if (!$value$plusargs("RESULT_FILE=%s", result_file)) result_file = { $sformatf("%m"), "_result.txt"};

    fd = $fopen(result_file, "w");
    if (fd == 0) begin
      $display("ERROR: Cannot open result file");
      $finish;
    end

    $display("==== REGFILE TEST START ====");


    // Init
    rd_we    = 0;
    rd_addr  = 0;
    rd_data  = 0;
    rs1_addr = 0;
    rs2_addr = 0;


    // RESET TEST
    rst_n = 0;
    repeat (2) @(posedge clk);
    rst_n = 1;

    rs1_addr = 5'd1;
    rs2_addr = 5'd2;
    @(posedge clk);
    check(rs1_data, 0, "reset rs1=0");
    check(rs2_data, 0, "reset rs2=0");


    // WRITE + READ TEST
    write_reg(5'd1, 64'hA5A5A5A5A5A5A5A5);
    read_rs1(5'd1, 64'hA5A5A5A5A5A5A5A5, "write/read rs1");


    // SECOND PORT TEST
    write_reg(5'd2, 64'h12345678ABCDEF00);
    read_rs2(5'd2, 64'h12345678ABCDEF00, "write/read rs2");


    // DUAL READ TEST
    rs1_addr = 5'd1;
    rs2_addr = 5'd2;
    @(posedge clk);

    check(rs1_data, 64'hA5A5A5A5A5A5A5A5, "dual read rs1");
    check(rs2_data, 64'h12345678ABCDEF00, "dual read rs2");


    // WRITE DISABLE TEST
    @(posedge clk);
    rd_addr = 5'd3;
    rd_data = 64'hFFFFFFFFFFFFFFFF;
    rd_we   = 0;
    @(posedge clk);

    read_rs1(5'd3, 0, "write disable");


    // x0 REGISTER TEST
    write_reg(5'd0, 64'hFFFFFFFFFFFFFFFF);
    read_rs1(5'd0, 0, "x0 always zero");


    // OVERWRITE TEST
    write_reg(5'd1, 64'h1111);
    read_rs1(5'd1, 64'h1111, "overwrite");


    // READ-AFTER-WRITE (NEXT CYCLE)
    write_reg(5'd4, 64'hDEADAABB);
    read_rs1(5'd4, 64'hDEADAABB, "RAW next cycle");

    // write + immediate read (same cycle) → should NOT see new data
    // Setup write + read in same cycle
    @(posedge clk);
    rd_addr  = 5'd5;
    rd_data  = 64'hCAFEBABE;
    rd_we    = 1;
    rs1_addr = 5'd5;

    // Next cycle: read should still be OLD (0)
    @(posedge clk);
    rd_we = 0;

    check(rs1_data, 0, "RAW same cycle (old value)");


    // RESULT FILE
    $fdisplay(fd, "TEST_NAME=tb_f_regfile");
    $fdisplay(fd, "PASS=%0d", pass_count);
    $fdisplay(fd, "FAIL=%0d", fail_count);
    $fdisplay(fd, "TOTAL=%0d", test_num);

    if (fail_count == 0) begin
      $fdisplay(fd, "STATUS=PASS");
    end else begin
      $fdisplay(fd, "STATUS=FAIL");
    end

    $fclose(fd);


    // SUMMARY

    $display("==== RESULT: PASS=%0d FAIL=%0d ====", pass_count, fail_count);

    if (fail_count == 0) $display("ALL PASS");
    else $fatal(1, "TEST FAILED");

    $finish;
  end

endmodule
