// =============================================================================
// tb_decoder.sv — FULL Decoder Verification Testbench
// =============================================================================

`timescale 1ns / 1ps

import isa_pkg::*;
import types_pkg::*;

module tb_decoder;

  // ---------------------------------------------------------------------------
  // DUT
  // ---------------------------------------------------------------------------
  logic           [31:0] instr;
  decoded_instr_t        dec;
  logic                  illegal;

  ins_decoder u_dut (
      .instr  (instr),
      .dec    (dec),
      .illegal(illegal)
  );

  // ---------------------------------------------------------------------------
  // Test infra
  // ---------------------------------------------------------------------------
  int pass_count = 0;
  int fail_count = 0;
  int test_num = 0;

  int fd;
  string result_file;

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------
  task automatic check_field(input logic [63:0] got, input logic [63:0] expected,
                             input string field, input string name);
    test_num++;
    if (got === expected) begin
      pass_count++;
      $display("[PASS] #%0d %-8s %-12s = %h", test_num, name, field, got);
    end else begin
      fail_count++;
      $display("[FAIL] #%0d %-8s %-12s exp=%h got=%h", test_num, name, field, expected, got);
    end
  endtask

  task automatic check_instruction(input instruction_t got, input instruction_t expected,
                                   input string name);
    test_num++;
    if (got === expected) begin
      pass_count++;
      $display("[PASS] #%0d %-8s instruction=%s", test_num, name, got.name());
    end else begin
      fail_count++;
      $display("[FAIL] #%0d %-8s instruction exp=%s got=%s", test_num, name, expected.name(),
               got.name());
    end
  endtask

  task automatic check_consistency(input string name);
    begin
      if (dec.mem_read && dec.mem_write) begin
        fail_count++;
        $display("[FAIL] %s mem_read and mem_write both set", name);
      end

      if (dec.branch && dec.reg_write) begin
        fail_count++;
        $display("[FAIL] %s branch unexpectedly writes register", name);
      end
    end
  endtask


  // ---------------------------------------------------------------------------
  // Waveform
  // ---------------------------------------------------------------------------
`ifdef ENABLE_WAVE
  initial begin
    if ($test$plusargs("WAVE")) begin
      $display("[WAVE] Enabled");
      $wdbDumpvars(0, tb_decoder);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // TEST SEQUENCE
  // ---------------------------------------------------------------------------
  initial begin

    // Result file
    if (!$value$plusargs("RESULT_FILE=%s", result_file))
      result_file = {$sformatf("%m"), "_result.txt"};

    fd = $fopen(result_file, "w");
    if (fd == 0) begin
      $fatal("Cannot open result file");
    end

    $display("==== DECODER TEST START ====");


    // ADDI
    instr = {12'd42, 5'd0, 3'b000, 5'd1, 7'b0010011};
    #1;
    check_field(dec.rd, 1, "rd", "ADDI");
    check_field(dec.rs1, 0, "rs1", "ADDI");
    check_field(dec.imm, 42, "imm", "ADDI");
    check_instruction(dec.instruction, INST_ADD, "ADDI");
    check_field(dec.alu_src, 1, "alu_src", "ADDI");
    check_field(dec.reg_write, 1, "reg_write", "ADDI");

    // ADDI x1,x0,-1
    instr = {12'hFFF, 5'd0, 3'b000, 5'd1, 7'b0010011};
    #1;
    check_field(dec.imm, 64'hFFFF_FFFF_FFFF_FFFF, "imm", "ADDI_NEG");

    // ADD
    instr = {7'b0000000, 5'd2, 5'd1, 3'b000, 5'd3, 7'b0110011};
    #1;
    check_field(dec.rd, 3, "rd", "ADD");
    check_field(dec.rs1, 1, "rs1", "ADD");
    check_field(dec.rs2, 2, "rs2", "ADD");
    check_instruction(dec.instruction, INST_ADD, "ADD");
    check_field(dec.alu_src, 0, "alu_src", "ADD");


    // SUB
    instr = {7'b0100000, 5'd2, 5'd1, 3'b000, 5'd3, 7'b0110011};
    #1;
    check_instruction(dec.instruction, INST_SUB, "SUB");


    // LW
    instr = {12'd8, 5'd2, 3'b010, 5'd5, 7'b0000011};
    #1;
    check_field(dec.mem_read, 1, "mem_read", "LW");
    check_field(dec.reg_write, 1, "reg_write", "LW");
    check_field(dec.imm, 8, "imm", "LW");
    check_instruction(dec.instruction, INST_ADD, "LW");


    // SW
    instr = {7'b0000000, 5'd5, 5'd2, 3'b010, 5'b10000, 7'b0100011};
    #1;
    check_field(dec.mem_write, 1, "mem_write", "SW");
    check_field(dec.imm, 16, "imm", "SW");
    check_instruction(dec.instruction, INST_ADD, "SW");

    // SW x5,-8(x2)

    instr = {7'b1111111, 5'd5, 5'd2, 3'b010, 5'b11000, 7'b0100011};
    #1;
    check_field(dec.imm, 64'hFFFF_FFFF_FFFF_FFF8, "imm", "SW_NEG");

    // BEQ
    instr = {1'b0, 6'b000000, 5'd2, 5'd1, 3'b000, 4'b0100, 1'b0, 7'b1100011};
    #1;
    check_field(dec.branch, 1, "branch", "BEQ");
    check_field(dec.imm, 8, "imm", "BEQ");
    check_instruction(dec.instruction, INST_SUB, "BEQ");

    // BEQ x1,x2,-16
    instr = {1'b1, 6'b111111, 5'd2, 5'd1, 3'b000, 4'b1000, 1'b1, 7'b1100011};
    #1;
    check_field(dec.imm, 64'hFFFF_FFFF_FFFF_FFF0, "imm", "BEQ_NEG");

    // JAL
    instr = {1'b0, 10'b0000000010, 1'b0, 8'b0, 5'd1, 7'b1101111};
    #1;
    check_field(dec.jal, 1, "jal", "JAL");
    check_field(dec.reg_write, 1, "reg_write", "JAL");
    check_field(dec.imm, 4, "imm", "JAL");


    // LUI
    instr = {20'hDEAD, 5'd1, 7'b0110111};
    #1;
    check_instruction(dec.instruction, INST_LUI, "LUI");
    check_field(dec.imm, 64'hDEAD000, "imm", "LUI");


    // FPU: FADD.D
    // funct7=0000001, rm=000
    instr = {7'b0000001, 5'd2, 5'd1, 3'b000, 5'd3, 7'b1010011};
    #1;

    check_field(dec.is_fp, 1, "is_fp", "FADD");
    check_field(dec.rd, 3, "rd", "FADD");
    check_field(dec.rs1, 1, "rs1", "FADD");
    check_field(dec.rs2, 2, "rs2", "FADD");
    check_instruction(dec.instruction, INST_FADD, "FADD");
    check_field(dec.fp_rm, 3'b000, "fp_rm", "FADD");
    check_field(dec.fp_funct5, 5'b00000, "fp_funct5", "FADD");


    // FPU: FSUB.D
    instr = {7'b0000101, 5'd2, 5'd1, 3'b000, 5'd3, 7'b1010011};
    #1;

    check_field(dec.is_fp, 1, "is_fp", "FSUB");
    check_instruction(dec.instruction, INST_FSUB, "FSUB");


    // FPU: FMUL.D
    instr = {7'b0001001, 5'd2, 5'd1, 3'b000, 5'd3, 7'b1010011};
    #1;

    check_instruction(dec.instruction, INST_FMUL, "FMUL");


    // FPU: FDIV.D
    instr = {7'b0001101, 5'd2, 5'd1, 3'b000, 5'd3, 7'b1010011};
    #1;

    check_instruction(dec.instruction, INST_FDIV, "FDIV");


    // FPU: FSQRT.D (rs2 ignored → set 0)
    instr = {7'b0101101, 5'd0, 5'd1, 3'b000, 5'd3, 7'b1010011};
    #1;

    check_instruction(dec.instruction, INST_FSQRT, "FSQRT");


    // FPU: FCMP (FEQ.D example rm=010)
    instr = {7'b1010001, 5'd2, 5'd1, 3'b010, 5'd3, 7'b1010011};
    #1;

    check_instruction(dec.instruction, INST_FCMP, "FCMP");
    check_field(dec.fp_rm, 3'b010, "fp_rm", "FCMP");


    // FPU: FCVT (int <-> float)
    instr = {7'b1100001, 5'd2, 5'd1, 3'b000, 5'd3, 7'b1010011};
    #1;
    check_instruction(dec.instruction, INST_FCVT, "FCVT");


    instr = {7'b1100001, 5'b11111, 5'd1, 3'b000, 5'd3, 7'b1010011};
    #1;
    test_num++;

    if (illegal) begin
      pass_count++;
      $display("[PASS] Illegal FCVT encoding detected");
    end else begin
      fail_count++;
      $display("[FAIL] Illegal FCVT encoding not detected");
    end


    // FCVT.W.D
    instr = {7'b1100001, 5'b00000, 5'd1, 3'b000, 5'd3, 7'b1010011};
    #1;
    check_instruction(dec.instruction, INST_FCVT, "FCVT.W.D");
    check_field(dec.fp_cvt_toint, 1, "toint", "FCVT.W.D");
    check_field(dec.fp_cvt_word, 1, "word", "FCVT.W.D");
    check_field(dec.fp_cvt_signed, 1, "signed", "FCVT.W.D");


    // FCVT.WU.D
    instr = {7'b1100001, 5'b00001, 5'd1, 3'b000, 5'd3, 7'b1010011};
    #1;
    check_field(dec.fp_cvt_toint, 1, "toint", "FCVT.WU.D");
    check_field(dec.fp_cvt_word, 1, "word", "FCVT.WU.D");
    check_field(dec.fp_cvt_signed, 0, "signed", "FCVT.WU.D");


    // FCVT.L.D
    instr = {7'b1100001, 5'b00010, 5'd1, 3'b000, 5'd3, 7'b1010011};
    #1;
    check_field(dec.fp_cvt_toint, 1, "toint", "FCVT.L.D");
    check_field(dec.fp_cvt_word, 0, "word", "FCVT.L.D");
    check_field(dec.fp_cvt_signed, 1, "signed", "FCVT.L.D");


    // FCVT.LU.D
    instr = {7'b1100001, 5'b00011, 5'd1, 3'b000, 5'd3, 7'b1010011};
    #1;
    check_field(dec.fp_cvt_toint, 1, "toint", "FCVT.LU.D");
    check_field(dec.fp_cvt_word, 0, "word", "FCVT.LU.D");
    check_field(dec.fp_cvt_signed, 0, "signed", "FCVT.LU.D");

    // FLT.D
    instr = {7'b1010001, 5'd2, 5'd1, 3'b001, 5'd3, 7'b1010011};
    #1;
    check_instruction(dec.instruction, INST_FCMP, "FLT.D");
    check_field(dec.fp_rm, 3'b001, "fp_rm", "FLT.D");

    // FLE.D
    instr = {7'b1010001, 5'd2, 5'd1, 3'b000, 5'd3, 7'b1010011};
    #1;
    check_instruction(dec.instruction, INST_FCMP, "FLE.D");
    check_field(dec.fp_rm, 3'b000, "fp_rm", "FLE.D");


    // FPU: ILLEGAL funct7
    instr = {7'b1111111, 5'd2, 5'd1, 3'b000, 5'd3, 7'b1010011};
    #1;


    // ILLEGAL
    instr = 32'hFFFF_FFFF;
    #1;
    test_num++;
    if (illegal) begin
      pass_count++;
      $display("[PASS] #%0d ILLEGAL detected", test_num);
    end else begin
      fail_count++;
      $display("[FAIL] #%0d ILLEGAL not detected", test_num);
    end



    // WRITE RESULT

    $fdisplay(fd, "TEST_NAME=tb_ins_decoder");
    $fdisplay(fd, "PASS=%0d", pass_count);
    $fdisplay(fd, "FAIL=%0d", fail_count);
    $fdisplay(fd, "TOTAL=%0d", test_num);
    $fdisplay(fd, "STATUS=%s", (fail_count == 0) ? "PASS" : "FAIL");
    $fclose(fd);


    // SUMMARY

    $display("==== RESULT: PASS=%0d FAIL=%0d ====", pass_count, fail_count);

    if (fail_count == 0) $display("ALL TESTS PASSED");
    else $fatal(1, "TEST FAILED");

    $finish;
  end

endmodule
