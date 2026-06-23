// =============================================================================
// tb_alu.sv — ALU Unit Testbench
// =============================================================================

`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// Package imports
// -----------------------------------------------------------------------------
import isa_pkg::*;
import types_pkg::*;

// Top TB
module tb_alu;

  // DUT connections
  instruction_t      inst;
  logic [63:0]  operand_a, operand_b;
  logic [63:0]  result;
  logic         zero, negative, overflow, carry;

  alu_top u_dut (
      .inst         (inst),
      .operand_a  (operand_a),
      .operand_b  (operand_b),
      .result     (result),
      .zero       (zero),
      .negative   (negative),
      .overflow   (overflow),
      .carry      (carry)
  );

  // ---------------------------------------------------------------------------
  // Test infrastructure
  // ---------------------------------------------------------------------------
  int pass_count = 0;
  int fail_count = 0;
  int test_num   = 0;

  int fd;
  string result_file;

  task automatic check(
      input instruction_t     t_op,
      input logic [63:0] a, b,
      input logic [63:0] expected,
      input string       test_name
  );
    inst        = t_op;
    operand_a = a;
    operand_b = b;

    #1;

    test_num++;

    if (result === expected) begin
      $display("[PASS] #%0d %-20s inst=%-8s a=%016h b=%016h got=%016h",
               test_num, test_name, inst.name(), a, b, result);
      pass_count++;
    end else begin
      $display("[FAIL] #%0d %-20s inst=%-8s a=%016h b=%016h exp=%016h got=%016h",
               test_num, test_name, inst.name(), a, b, expected, result);
      fail_count++;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Waveform
  // ----------------------------------------------------------------------------
`ifdef ENABLE_WAVE
  initial begin
    $dumpfile("tb_alu.vcd");
    $dumpvars(0, tb_alu);
  end
`endif

  // ---------------------------------------------------------------------------
  // Tests
  // ---------------------------------------------------------------------------
  initial begin

    // -------------------------------
    // Get result file path
    // -------------------------------
    if (!$value$plusargs("RESULT_FILE=%s", result_file)) begin
      result_file = "tb_alu_result.txt";
    end

    fd = $fopen(result_file, "w");
    if (fd == 0) begin
      $display("ERROR: Cannot open result file");
      $finish;
    end


    $display("==== ALU TEST START ====");

    inst = INST_NOP;
    operand_a = '0;
    operand_b = '0;
    #5;

    // ADD
    check(INST_ADD, 10, 20, 30, "ADD basic");
    check(INST_ADD, 64'hFFFF_FFFF_FFFF_FFFF, 1, 0, "ADD overflow");

    // SUB
    check(INST_SUB, 100, 40, 60, "SUB basic");

    // LOGIC
    check(INST_AND, 64'hF0F0, 64'hFF00, 64'hF000, "AND");
    check(INST_OR,  64'hF0F0, 64'h0F0F, 64'hFFFF, "OR");

    // SHIFT
    check(INST_SLL, 1, 4, 16, "SLL");

    // COMPARE
    check(INST_SLT, 5, 10, 1, "SLT");

    // FLAGS
    inst = INST_SUB; operand_a = 5; operand_b = 5; #1;
    if (zero) pass_count++; else fail_count++;
    test_num++;

    // -------------------------------
    // Write result file
    // -------------------------------
    $fdisplay(fd, "TEST_NAME=tb_alu");
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

    if (fail_count == 0) begin
      $display("ALL PASS");
    end else begin
      $fatal(1, "TEST FAILED");
    end

    $finish;
  end

endmodule