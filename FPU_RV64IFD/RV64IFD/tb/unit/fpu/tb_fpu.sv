
// tb_fpu.sv — FPU Unit Testbench
//
// Mirrors tb_alu.sv style exactly:
//   - Same check() task signature pattern
//   - Same pass/fail counters
//   - Same RESULT_FILE plusarg mechanism
//   - Same waveform ifdef guard
//
// Tests:
//   FADD.D  — basic add, carry, sign, NaN, Inf
//   FSUB.D  — basic subtract, cancellation
//   FMUL.D  — basic multiply, zero × Inf, overflow
//   FDIV.D  — basic divide, /0, NaN input
//   FSQRT.D — exact squares, zero, negative --> NaN
//   FCMP    — FEQ / FLT / FLE including NaN rules
//   FCVT    — float-->int, int-->float (32/64-bit signed)


`timescale 1ns / 1ps

import isa_pkg::*;
import pkg_fpu_types::*;
import types_pkg::*;

module tb_fpu;


  // DUT signals
  logic clk, rst_n;
  instruction_t        inst;
  logic         [ 4:0] fp_funct5;
  logic                fp_cvt_toint;
  logic                fp_cvt_word;
  logic                fp_cvt_signed;
  logic         [ 2:0] fp_rm;
  logic         [ 1:0] fp_fmt;
  logic         [ 1:0] fp_sgn_op;
  logic                fp_min_sel;
  logic         [63:0] int_operand;
  logic [63:0] operand_a, operand_b;
  logic [63:0] result;
  logic        to_int;
  logic [ 4:0] fflags;

  fpu_top u_dut (
      .clk  (clk),
      .rst_n(rst_n),

      .inst(inst),
      .fp_funct5(fp_funct5),
      .fp_rm(fp_rm),

      .fp_cvt_toint (fp_cvt_toint),
      .fp_cvt_word  (fp_cvt_word),
      .fp_cvt_signed(fp_cvt_signed),

      .fp_fmt(fp_fmt),
      .fp_sgn_op(fp_sgn_op),
      .fp_min_sel(fp_min_sel),

      .operand_a(operand_a),
      .operand_b(operand_b),

      .int_operand(int_operand),

      .result(result),
      .to_int(to_int),
      .fflags(fflags),

      .div_valid_in(1'b1),
      .div_ready(),
      .div_valid_out()
  );

  // Clock: 100 MHz
  initial clk = 0;
  always #5 clk = ~clk;


  // Test infrastructure  (matches tb_alu.sv)

  int pass_count = 0;
  int fail_count = 0;
  int test_num   = 0;

  int    fd;
  string result_file;

  // Generic result check
  task automatic check(input logic [63:0] got, input logic [63:0] expected, input string name);
    test_num++;
    if (got === expected) begin
      $display("[PASS] #%0d %-30s got=%016h", test_num, name, got);
      pass_count++;
    end else begin
      $display("[FAIL] #%0d %-30s exp=%016h got=%016h", test_num, name, expected, got);
      fail_count++;
    end
  endtask

  // FP operation helper: set inputs, wait 1ns for combinational settle
  task automatic fpu_op(input instruction_t t_inst, input logic [4:0] t_funct5,
                        input logic [2:0] t_rm, input logic t_cvt_toint, input logic [63:0] a,
                        input logic [63:0] b);
    begin
      inst          = t_inst;
      fp_funct5     = t_funct5;
      fp_rm         = t_rm;

      fp_cvt_toint  = t_cvt_toint;
      fp_cvt_word   = 1'b0;
      fp_cvt_signed = 1'b1;

      fp_fmt        = FP_FMT_D;

      fp_sgn_op     = 2'b00;
      fp_min_sel    = 1'b0;

      int_operand   = 64'd0;

      operand_a     = a;
      operand_b     = b;

      #1;
    end
  endtask

  task automatic fpu_cvt_op(input logic t_to_int, input logic [1:0] t_fmt, input logic t_word,
                            input logic t_signed, input logic [63:0] a);
    begin
      inst          = INST_FCVT;

      fp_funct5     = 5'd0;
      fp_rm         = 3'b000;

      fp_fmt        = t_fmt;

      fp_cvt_toint  = t_to_int;
      fp_cvt_word   = t_word;
      fp_cvt_signed = t_signed;

      fp_sgn_op     = 2'b00;
      fp_min_sel    = 1'b0;

      int_operand   = a;

      operand_a     = a;
      operand_b     = 64'd0;

      #1;
    end
  endtask

  // fflags check helper
  task automatic check_fflags(input logic [4:0] got, input logic [4:0] expected, input string name);
    test_num++;
    if (got === expected) begin
      $display("[PASS] #%0d %-30s fflags=%05b", test_num, name, got);
      pass_count++;
    end else begin
      $display("[FAIL] #%0d %-30s fflags exp=%05b got=%05b", test_num, name, expected, got);
      fail_count++;
    end
  endtask

  task automatic fsgnj_op(input instruction_t t_inst, input logic [1:0] t_sgn_op,
                          input logic [63:0] a, input logic [63:0] b);
    begin
      inst      = t_inst;
      fp_sgn_op = t_sgn_op;
      fp_fmt    = FP_FMT_D;

      operand_a = a;
      operand_b = b;

      #1;
    end
  endtask

  task automatic fminmax_op(input logic t_min_sel, input logic [63:0] a, input logic [63:0] b);
    begin
      inst       = INST_FMINMAX;
      fp_min_sel = t_min_sel;
      fp_fmt     = FP_FMT_D;

      operand_a  = a;
      operand_b  = b;

      #1;
    end
  endtask

  task automatic fmv_op(input instruction_t t_inst, input logic [63:0] fp_val,
                        input logic [63:0] int_val);
    begin
      inst        = t_inst;
      operand_a   = fp_val;
      int_operand = int_val;

      #1;
    end
  endtask

  task automatic check_to_int(input logic expected, input string name);
    begin
      test_num++;

      if (to_int === expected) begin
        pass_count++;
        $display("[PASS] %s", name);
      end else begin
        fail_count++;
        $display("[FAIL] %s", name);
      end
    end
  endtask


  // IEEE 754 double-precision helpers
  // Encode/decode without relying on real-type arithmetic to keep
  // the testbench synthesizer-agnostic.


  // Pack a double from components
  function automatic logic [63:0] fp64(input logic sign, input logic [10:0] exp,
                                       input logic [51:0] frac);
    return {sign, exp, frac};
  endfunction

  // Common IEEE-754 double-precision constants
  localparam logic [63:0] F64_MAX = 64'h7FEFFFFFFFFFFFFF;
  localparam logic [63:0] F64_ZERO = 64'h0000_0000_0000_0000;  // +0.0
  localparam logic [63:0] F64_NEG_ZERO = 64'h8000_0000_0000_0000;  // -0.0

  localparam logic [63:0] F64_HALF = 64'h3FE0_0000_0000_0000;  // +0.5
  localparam logic [63:0] F64_ONE = 64'h3FF0_0000_0000_0000;  // +1.0
  localparam logic [63:0] F64_NEG_ONE = 64'hBFF0_0000_0000_0000;  // -1.0

  localparam logic [63:0] F64_1P25 = 64'h3FF4_0000_0000_0000;  // +1.25
  localparam logic [63:0] F64_1P5 = 64'h3FF8_0000_0000_0000;  // +1.5
  localparam logic [63:0] F64_1P75 = 64'h3FFC_0000_0000_0000;  // +1.75

  localparam logic [63:0] F64_1P6666 = 64'h3FFAAA64C2F837B5;  // ~1.6666
  localparam logic [63:0] F64_1P3333 = 64'h3FF55532617C1BDA;  // ~1.3333
  localparam logic [63:0] F64_2P9999 = 64'h4007FFCB923A29C8;  // ~2.9999 ->NRE

  localparam logic [63:0] F64_TWO = 64'h4000_0000_0000_0000;  // +2.0
  localparam logic [63:0] F64_THREE = 64'h4008_0000_0000_0000;  // +3.0
  localparam logic [63:0] F64_FOUR = 64'h4010_0000_0000_0000;  // +4.0
  localparam logic [63:0] F64_FIVE = 64'h4014_0000_0000_0000;  // +5.0

  localparam logic [63:0] F64_TEN = 64'h4024_0000_0000_0000;  // +10.0

  // Fractions useful for normalization/rounding tests
  localparam logic [63:0] F64_QUARTER = 64'h3FD0_0000_0000_0000;  // +0.25
  localparam logic [63:0] F64_EIGHTH = 64'h3FC0_0000_0000_0000;  // +0.125

  // Special values
  localparam logic [63:0] F64_INF_POS = 64'h7FF0_0000_0000_0000;  // +Inf
  localparam logic [63:0] F64_INF_NEG = 64'hFFF0_0000_0000_0000;  // -Inf
  localparam logic [63:0] F64_QNAN = 64'h7FF8_0000_0000_0000;  // Quiet NaN
  // 4.0 (already above)
  // sqrt(4) = 2.0  --> use F64_TWO
  // sqrt(1) = 1.0  --> use F64_ONE

  // Rounding-mode test values
  localparam logic [63:0] F64_HALF_ULP = 64'h3CA0_0000_0000_0000;  // 2^-53
  localparam logic [63:0] F64_ONE_ULP = 64'h3CB0_0000_0000_0000;  // 2^-52

  localparam logic [63:0] F64_ONE_PLUS_ULP = 64'h3FF0_0000_0000_0001;

  localparam logic [63:0] F64_NEG_ONE_MINUS_ULP = 64'hBFF0_0000_0000_0001;

`ifdef ENABLE_WAVE
  initial begin
    $dumpfile("tb_fpu.vcd");
    $dumpvars(0, tb_fpu);
  end
`endif


  // Reset

  initial begin
    rst_n         = 0;
    inst          = INST_NOP;
    fp_funct5     = 5'd0;
    fp_rm         = 3'b000;  // RNE

    fp_fmt        = FP_FMT_D;

    fp_cvt_toint  = 1'b0;

    fp_cvt_word   = 1'b0;
    fp_cvt_signed = 1'b1;

    fp_sgn_op     = 2'b00;
    fp_min_sel    = 1'b0;

    int_operand   = 64'd0;

    operand_a     = '0;
    operand_b     = '0;
    @(posedge clk);
    #1;
    rst_n = 1;
    @(posedge clk);
    #1;
  end


  // Tests

  initial begin
    // Wait for reset
    @(posedge rst_n);
    #2;


    // Get result file

    if (!$value$plusargs("RESULT_FILE=%s", result_file)) begin
      result_file = "tb_fpu_result.txt";
    end

    fd = $fopen(result_file, "w");
    if (fd == 0) begin
      $display("ERROR: Cannot open result file");
      $finish;
    end

    $display("==== FPU TEST START ====");


    // FADD.D
    $display("--- FADD.D ---");

    // 1.0 + 1.0 = 2.0
    fpu_op(INST_FADD, 5'b00000, 3'b000, 1'b0, F64_ONE, F64_ONE);
    $display("DEBUG: addsub_en=%b res_sel=%0d addsub_r=%h result=%h", u_dut.addsub_en,
             u_dut.res_sel, u_dut.addsub_r, result);
    check(result, F64_TWO, "FADD 1+1=2");

    // 1.0 + (-1.0) = 0.0
    fpu_op(INST_FADD, 5'b00000, 3'b000, 1'b0, F64_ONE, F64_NEG_ONE);
    check(result, F64_ZERO, "FADD 1+(-1)=0");

    // 1.5 + 0.5 = 2.0
    fpu_op(INST_FADD, 5'b00000, 3'b000, 1'b0, F64_1P5, F64_HALF);
    check(result, F64_TWO, "FADD 1.5+0.5=2");

    // 1.25 + 1.75 = 3.0
    fpu_op(INST_FADD, 5'b00000, 3'b000, 1'b0, F64_1P25, F64_1P75);
    check(result, F64_THREE, "FADD 1.25+1.75=3");

    // 1.75 + 1.75 = 3.5
    fpu_op(INST_FADD, 5'b00000, 3'b000, 1'b0, F64_1P75, F64_1P75);
    check(result, 64'h400C_0000_0000_0000, "FADD 1.75+1.75=3.5");

    // 1.5 + 1.5 = 3.0
    fpu_op(INST_FADD, 5'b00000, 3'b000, 1'b0, F64_1P5, F64_1P5);
    check(result, F64_THREE, "FADD 1.5+1.5=3");

    // 1.6666 + 1.3333 ≈ 2.9999
    fpu_op(INST_FADD, 5'b00000, 3'b000, 1'b0, F64_1P6666, F64_1P3333);
    check(result, F64_2P9999, "FADD 1.6666+1.3333");

    // +0 + -0 = +0
    fpu_op(INST_FADD, 5'b00000, 3'b000, 1'b0, F64_ZERO, F64_NEG_ZERO);
    check(result, F64_ZERO, "FADD +0 + -0");

    // 1 - 2 = -1
    fpu_op(INST_FSUB, 5'b00001, 3'b000, 1'b0, F64_ONE, F64_TWO);
    check(result, F64_NEG_ONE, "FSUB 1-2=-1");

    // +Inf + +Inf = +Inf
    fpu_op(INST_FADD, 5'b00000, 3'b000, 1'b0, F64_INF_POS, F64_INF_POS);
    check(result, F64_INF_POS, "FADD Inf+Inf=Inf");

    // +Inf + -Inf = NaN (invalid)
    fpu_op(INST_FADD, 5'b00000, 3'b000, 1'b0, F64_INF_POS, F64_INF_NEG);
    check(result, F64_QNAN, "FADD Inf+(-Inf)=NaN");
    check_fflags(fflags, 5'b10000, "FADD Inf+(-Inf) NV flag");

    // NaN input --> NaN out
    fpu_op(INST_FADD, 5'b00000, 3'b000, 1'b0, F64_QNAN, F64_ONE);
    check(result, F64_QNAN, "FADD NaN+1=NaN");


    // FSUB.D
    $display("--- FSUB.D ---");

    // 2.0 - 1.0 = 1.0
    fpu_op(INST_FSUB, 5'b00001, 3'b000, 1'b0, F64_TWO, F64_ONE);
    check(result, F64_ONE, "FSUB 2-1=1");

    // 1.0 - 1.0 = 0.0
    fpu_op(INST_FSUB, 5'b00001, 3'b000, 1'b0, F64_ONE, F64_ONE);
    check(result, F64_ZERO, "FSUB 1-1=0");

    // 3.0 - 1.75 = 1.25
    fpu_op(INST_FSUB, 5'b00001, 3'b000, 1'b0, F64_THREE, F64_1P75);
    check(result, F64_1P25, "FSUB 3-1.75=1.25");

    // 1.75 - 1.5 = 0.25
    fpu_op(INST_FSUB, 5'b00001, 3'b000, 1'b0, F64_1P75, F64_1P5);
    check(result, F64_QUARTER, "FSUB 1.75-1.5=0.25");

    // 4.0 - 1.75 = 2.25
    fpu_op(INST_FSUB, 5'b00001, 3'b000, 1'b0, F64_FOUR, F64_1P75);
    check(result, 64'h4002_0000_0000_0000, "FSUB 4-1.75=2.25");

    //@todo: add cases for cancellation, denormal/subnormal handling and signed zero


    // FMUL.D
    $display("--- FMUL.D ---");

    // 2.0 × 2.0 = 4.0
    fpu_op(INST_FMUL, 5'b00010, 3'b000, 1'b0, F64_TWO, F64_TWO);
    check(result, F64_FOUR, "FMUL 2×2=4");

    // 1.0 × (-1.0) = -1.0: Sign combinations
    fpu_op(INST_FMUL, 5'b00010, 3'b000, 1'b0, F64_ONE, F64_NEG_ONE);
    check(result, F64_NEG_ONE, "FMUL 1×(-1)=-1");

    // (-2) × (-2) = +4 : Sign combinations
    fpu_op(INST_FMUL, 5'b00010, 3'b000, 1'b0, 64'hC000000000000000, 64'hC000000000000000);
    check(result, F64_FOUR, "FMUL (-2)×(-2)=4");

    // (-2) × (+2) = -4 : Sign combinations
    fpu_op(INST_FMUL, 5'b00010, 3'b000, 1'b0, 64'hC000000000000000, F64_TWO);
    check(result, 64'hC010000000000000, "FMUL (-2)×2=-4");

    // 1.5 × 2.0 = 3.0
    fpu_op(INST_FMUL, 5'b00010, 3'b000, 1'b0, F64_1P5, F64_TWO);
    check(result, F64_THREE, "FMUL 1.5×2=3");

    // 1.5 × 1.5 = 2.25: Fraction normalization
    fpu_op(INST_FMUL, 5'b00010, 3'b000, 1'b0, F64_1P5, F64_1P5);
    check(result, 64'h4002000000000000, "FMUL 1.5×1.5=2.25");

    // (-0) × 2 = -0 : Zero sign rules
    fpu_op(INST_FMUL, 5'b00010, 3'b000, 1'b0, F64_NEG_ZERO, F64_TWO);
    check(result, F64_NEG_ZERO, "FMUL -0×2=-0");

    // (-0) × (-1) = +0
    fpu_op(INST_FMUL, 5'b00010, 3'b000, 1'b0, F64_NEG_ZERO, F64_NEG_ONE);
    check(result, F64_ZERO, "FMUL -0×(-1)=+0");

    // 0 × +Inf = NaN (invalid)
    fpu_op(INST_FMUL, 5'b00010, 3'b000, 1'b0, F64_ZERO, F64_INF_POS);
    check(result, F64_QNAN, "FMUL 0×Inf=NaN");
    check_fflags(fflags, 5'b10000, "FMUL 0×Inf NV flag");

    // Inf × 2 = Inf
    fpu_op(INST_FMUL, 5'b00010, 3'b000, 1'b0, F64_INF_POS, F64_TWO);
    check(result, F64_INF_POS, "FMUL Inf×2=Inf");

    //Infinity sign rules
    // +Inf × -1 = -Inf
    fpu_op(INST_FMUL, 5'b00010, 3'b000, 1'b0, F64_INF_POS, F64_NEG_ONE);
    check(result, F64_INF_NEG, "FMUL Inf×(-1)=-Inf");

    // -Inf × -1 = +Inf
    fpu_op(INST_FMUL, 5'b00010, 3'b000, 1'b0, F64_INF_NEG, F64_NEG_ONE);
    check(result, F64_INF_POS, "FMUL -Inf×(-1)=+Inf");

    // NaN propagation
    // NaN × 2 = NaN
    fpu_op(INST_FMUL, 5'b00010, 3'b000, 1'b0, F64_QNAN, F64_TWO);
    check(result, F64_QNAN, "FMUL NaN×2=NaN");

    // Overflow
    // MAX × 2 = +Inf
    fpu_op(INST_FMUL, 5'b00010, 3'b000, 1'b0, F64_MAX, F64_TWO);
    check(result, F64_INF_POS, "FMUL MAX×2=Inf");
    check_fflags(fflags, 5'b00101, "FMUL overflow");

    // FDIV.D
    $display("--- FDIV.D ---");

    // 4.0 / 2.0 = 2.0
    fpu_op(INST_FDIV, 5'b00011, 3'b000, 1'b0, F64_FOUR, F64_TWO);
    check(result, F64_TWO, "FDIV 4/2=2");

    // (-4)/2 = -2
    fpu_op(INST_FDIV, 5'b00011, 3'b000, 1'b0, 64'hC010000000000000, F64_TWO);
    check(result, 64'hC000000000000000, "FDIV -4/2=-2");

    // 1/2 = 0.5
    fpu_op(INST_FDIV, 5'b00011, 3'b000, 1'b0, F64_ONE, F64_TWO);
    check(result, F64_HALF, "FDIV 1/2=0.5");

    // 1.5/2 
    fpu_op(INST_FDIV, 5'b00011, 3'b000, 1'b0, 64'h3FF8000000000000, F64_TWO);
    check(result, 64'h3FE8000000000000, "FDIV 1.5/2=0.75");

    // 2/3
    fpu_op(INST_FDIV, 5'b00011, 3'b000, 1'b0, F64_TWO, F64_THREE);
    check(result, 64'h3FE5555555555555, "FDIV 2/3");
    check_fflags(fflags, 5'b00001, "FDIV 2/3 NX");

    // Inf / Inf = NaN
    fpu_op(INST_FDIV, 5'b00011, 3'b000, 1'b0, F64_INF_POS, F64_INF_POS);
    check(result, F64_QNAN, "FDIV Inf/Inf=NaN");
    check_fflags(fflags, 5'b10000, "FDIV Inf/Inf NV");

    // 1.0 / 0.0 = +Inf (DZ flag)
    fpu_op(INST_FDIV, 5'b00011, 3'b000, 1'b0, F64_ONE, F64_ZERO);
    check(result, F64_INF_POS, "FDIV 1/0=+Inf");
    check_fflags(fflags, 5'b01000, "FDIV 1/0 DZ flag");

    // 0 / 0 = NaN (invalid)
    fpu_op(INST_FDIV, 5'b00011, 3'b000, 1'b0, F64_ZERO, F64_ZERO);
    check(result, F64_QNAN, "FDIV 0/0=NaN");

    // NaN / 2 = NaN
    fpu_op(INST_FDIV, 5'b00011, 3'b000, 1'b0, F64_QNAN, F64_TWO);
    check(result, F64_QNAN, "FDIV NaN/2=NaN");


    // FSQRT.D
    $display("--- FSQRT.D ---");

    // sqrt(1.0) = 1.0
    fpu_op(INST_FSQRT, 5'b01011, 3'b000, 1'b0, F64_ONE, F64_ZERO);
    check(result, F64_ONE, "FSQRT sqrt(1)=1");

    // sqrt(4.0) = 2.0
    fpu_op(INST_FSQRT, 5'b01011, 3'b000, 1'b0, F64_FOUR, F64_ZERO);
    check(result, F64_TWO, "FSQRT sqrt(4)=2");

    // sqrt(16.0) = 4.0
    fpu_op(INST_FSQRT, 5'b01011, 3'b000, 1'b0, 64'h4030000000000000, F64_ZERO);
    check(result, F64_FOUR, "FSQRT sqrt(16.0)=4.0");

    // sqrt(0.25)=0.5
    fpu_op(INST_FSQRT, 5'b01011, 3'b000, 1'b0, F64_QUARTER, F64_ZERO);
    check(result, F64_HALF, "FSQRT sqrt(0.25)");

    // sqrt(3)
    fpu_op(INST_FSQRT, 5'b01011, 3'b000, 1'b0, F64_THREE, F64_ZERO);
    check(result, 64'h3FFBB67AE8584CAB, "FSQRT sqrt(3)");
    check_fflags(fflags, 5'b00001, "FSQRT sqrt(3) NX");

    // sqrt(0) = 0
    fpu_op(INST_FSQRT, 5'b01011, 3'b000, 1'b0, F64_ZERO, F64_ZERO);
    check(result, F64_ZERO, "FSQRT sqrt(0)=0");

    // sqrt(-1) = NaN (invalid)
    fpu_op(INST_FSQRT, 5'b01011, 3'b000, 1'b0, F64_NEG_ONE, F64_ZERO);
    check(result, F64_QNAN, "FSQRT sqrt(-1)=NaN");
    check_fflags(fflags, 5'b10000, "FSQRT sqrt(-1) NV flag");

    // sqrt(+Inf) = +Inf
    fpu_op(INST_FSQRT, 5'b01011, 3'b000, 1'b0, F64_INF_POS, F64_ZERO);
    check(result, F64_INF_POS, "FSQRT sqrt(+Inf)=+Inf");

    // sqrt(2.0) ≈ 1.41421356237 : non-trivial exponent
    // IEEE-754 double: 0x3FF6A09E667F3BCD
    fpu_op(INST_FSQRT, 5'b01011, 3'b000, 1'b0, 64'h4000000000000000, F64_ZERO);
    // sqrt(2.0)
    check(result, 64'h3FF6A09E667F3BCD, "FSQRT sqrt(2.0)");

    // sqrt(0.5) ≈ 0.7071067811865476 : Subnormal handling
    // IEEE-754 double: 0x3FE6A09E667F3BCD
    fpu_op(INST_FSQRT, 5'b01011, 3'b000, 1'b0, 64'h3FE0000000000000, F64_ZERO);
    // 0.5
    check(result, 64'h3FE6A09E667F3BCD, "FSQRT sqrt(0.5)");

    // sqrt(10.0) ≈ 3.1622776601683795
    // 0x4004000000000000
    fpu_op(INST_FSQRT, 5'b01011, 3'b000, 1'b0, 64'h4024000000000000, F64_ZERO);
    check(result, 64'h40094c583ada5b53, "FSQRT sqrt(10)");


    // FCMP — FEQ / FLT / FLE
    // funct3/fp_rm encodes comparison:  010=FEQ, 001=FLT, 000=FLE
    $display("--- FCMP (FEQ/FLT/FLE) ---");

    // FEQ: 1.0 == 1.0 --> 1
    fpu_op(INST_FCMP, 5'b10100, 3'b010, 1'b0, F64_ONE, F64_ONE);
    check(result, 64'd1, "FEQ 1==1 --> 1");

    // FEQ: 1.0 == 2.0 --> 0
    fpu_op(INST_FCMP, 5'b10100, 3'b010, 1'b0, F64_ONE, F64_TWO);
    check(result, 64'd0, "FEQ 1==2 --> 0");

    // FEQ: NaN == NaN --> 0 (no NV for qNaN in FEQ per spec)
    fpu_op(INST_FCMP, 5'b10100, 3'b010, 1'b0, F64_QNAN, F64_QNAN);
    check(result, 64'd0, "FEQ NaN==NaN --> 0");

    // FLT: 1.0 < 2.0 --> 1
    fpu_op(INST_FCMP, 5'b10100, 3'b001, 1'b0, F64_ONE, F64_TWO);
    check(result, 64'd1, "FLT 1<2 --> 1");

    // FLT: 2.0 < 1.0 --> 0
    fpu_op(INST_FCMP, 5'b10100, 3'b001, 1'b0, F64_TWO, F64_ONE);
    check(result, 64'd0, "FLT 2<1 --> 0");

    // FLT: NaN < 1 --> 0, NV flag
    fpu_op(INST_FCMP, 5'b10100, 3'b001, 1'b0, F64_QNAN, F64_ONE);
    check(result, 64'd0, "FLT NaN<1 --> 0");
    check_fflags(fflags, 5'b10000, "FLT NaN<1 NV flag");

    // FLE: 1.0 <= 1.0 --> 1
    fpu_op(INST_FCMP, 5'b10100, 3'b000, 1'b0, F64_ONE, F64_ONE);
    check(result, 64'd1, "FLE 1<=1 --> 1");

    // FLE: 2.0 <= 1.0 --> 0
    fpu_op(INST_FCMP, 5'b10100, 3'b000, 1'b0, F64_TWO, F64_ONE);
    check(result, 64'd0, "FLE 2<=1 --> 0");

    // +0 == -0 --> 1 (IEEE rule)
    fpu_op(INST_FCMP, 5'b10100, 3'b010, 1'b0, F64_ZERO, F64_NEG_ZERO);
    check(result, 64'd1, "FEQ +0==-0 --> 1");

    $display("--- FSGNJ ---");

    // FSGNJ
    fsgnj_op(INST_FSGNJ, 2'b00, F64_ONE, F64_NEG_ONE);
    check(result, F64_NEG_ONE, "FSGNJ copy sign");

    // FSGNJN
    fsgnj_op(INST_FSGNJ, 2'b01, F64_ONE, F64_NEG_ONE);
    check(result, F64_ONE, "FSGNJN invert sign");

    // FSGNJX
    fsgnj_op(INST_FSGNJ, 2'b10, F64_ONE, F64_NEG_ONE);
    check(result, F64_NEG_ONE, "FSGNJX xor sign");

    // negative xor negative -> positive
    fsgnj_op(INST_FSGNJ, 2'b10, F64_NEG_ONE, F64_NEG_ONE);
    check(result, F64_ONE, "FSGNJX neg xor neg");

    $display("--- FMIN/FMAX ---");

    // FMIN
    fminmax_op(1'b1, F64_ONE, F64_TWO);
    check(result, F64_ONE, "FMIN(1,2)=1");

    // FMAX
    fminmax_op(1'b0, F64_ONE, F64_TWO);
    check(result, F64_TWO, "FMAX(1,2)=2");

    // FMIN(-0, +0) = -0
    fminmax_op(1'b1, 64'h8000000000000000, 64'h0000000000000000);
    check(result, 64'h8000000000000000, "FMIN(-0,+0)=-0");

    // FMAX(-0, +0) = +0
    fminmax_op(1'b0, 64'h8000000000000000, 64'h0000000000000000);
    check(result, 64'h0000000000000000, "FMAX(-0,+0)=+0");

    fminmax_op(1'b1, 64'h7FF8000000000001, 64'h7FF8000000000002);
    check(result, 64'h7FF8000000000000, "FMIN(NaN,NaN)=canonical NaN");

    fminmax_op(1'b0, 64'h7FF8000000000001, 64'h7FF8000000000002);
    check(result, 64'h7FF8000000000000, "FMAX(NaN,NaN)=canonical NaN");

    // negative values
    fminmax_op(1'b1, F64_NEG_ONE, F64_ONE);
    check(result, F64_NEG_ONE, "FMIN(-1,1)=-1");

    fminmax_op(1'b0, F64_NEG_ONE, F64_ONE);
    check(result, F64_ONE, "FMAX(-1,1)=1");

    // NaN vs number
    fminmax_op(1'b1, 64'h7FF8000000000001, F64_ONE);
    check(result, F64_ONE, "FMIN(NaN,1)=1");

    fminmax_op(1'b0, 64'h7FF8000000000001, F64_ONE);
    check(result, F64_ONE, "FMAX(NaN,1)=1");

    // number vs NaN
    fminmax_op(1'b1, F64_ONE, 64'h7FF8000000000001);
    check(result, F64_ONE, "FMIN(1,NaN)=1");

    fminmax_op(1'b0, F64_ONE, 64'h7FF8000000000001);
    check(result, F64_ONE, "FMAX(1,NaN)=1");

    // -2 vs -1
    fminmax_op(1'b1, 64'hC000000000000000, 64'hBFF0000000000000);
    check(result, 64'hC000000000000000, "FMIN(-2,-1)=-2");

    fminmax_op(1'b0, 64'hC000000000000000, 64'hBFF0000000000000);
    check(result, 64'hBFF0000000000000, "FMAX(-2,-1)=-1");

    // smallest subnormal vs 1.0
    fminmax_op(1'b1, 64'h0000000000000001, F64_ONE);
    check(result, 64'h0000000000000001, "FMIN(subnormal,1)=subnormal");

    fminmax_op(1'b0, 64'h0000000000000001, F64_ONE);
    check(result, F64_ONE, "FMAX(subnormal,1)=1");

    // +inf vs 1
    fminmax_op(1'b1, F64_INF_POS, F64_ONE);
    check(result, F64_ONE, "FMIN(+inf,1)=1");

    fminmax_op(1'b0, F64_INF_POS, F64_ONE);
    check(result, F64_INF_POS, "FMAX(+inf,1)=inf");

    // -inf vs 1
    fminmax_op(1'b1, F64_INF_NEG, F64_ONE);
    check(result, F64_INF_NEG, "FMIN(-inf,1)=-inf");

    fminmax_op(1'b0, F64_INF_NEG, F64_ONE);
    check(result, F64_ONE, "FMAX(-inf,1)=1");

    $display("--- FMV ---");

    // FMV.X.D
    fmv_op(INST_FMVXD, F64_ONE, 64'd0);
    check(result, F64_ONE, "FMV.X.D raw bits");

    test_num++;
    if (to_int) pass_count++;
    else begin
      fail_count++;
      $display("[FAIL] FMV.X.D to_int");
    end

    // FMV.D.X
    fmv_op(INST_FMVDX, 64'd0, F64_ONE);
    check(result, F64_ONE, "FMV.D.X raw bits");

    // ------------------------------------------------------------------
    // ROUNDING MODE TESTS
    // ------------------------------------------------------------------
    $display("--- ROUNDING MODES ---");

    // ============================================================
    // Tie case: 1.0 + 2^-53
    //
    // Exact value lies exactly halfway between:
    //
    //   1.0
    //   1.0 + 1ULP
    //
    // Expected:
    //   RNE -> 1.0
    //   RTZ -> 1.0
    //   RDN -> 1.0
    //   RUP -> 1.0 + ULP
    //   RMM -> 1.0 + ULP
    // ============================================================

    // RNE
    fpu_op(INST_FADD, 5'b00000, 3'b000, 1'b0, F64_ONE, F64_HALF_ULP);
    check(result, F64_ONE, "RM RNE tie");

    // RTZ
    fpu_op(INST_FADD, 5'b00000, 3'b001, 1'b0, F64_ONE, F64_HALF_ULP);
    check(result, F64_ONE, "RM RTZ tie");

    // RDN
    fpu_op(INST_FADD, 5'b00000, 3'b010, 1'b0, F64_ONE, F64_HALF_ULP);
    check(result, F64_ONE, "RM RDN tie");

    // RUP
    fpu_op(INST_FADD, 5'b00000, 3'b011, 1'b0, F64_ONE, F64_HALF_ULP);
    check(result, F64_ONE_PLUS_ULP, "RM RUP tie");

    // RMM
    fpu_op(INST_FADD, 5'b00000, 3'b100, 1'b0, F64_ONE, F64_HALF_ULP);
    check(result, F64_ONE_PLUS_ULP, "RM RMM tie");


    // ============================================================
    // Negative tie case
    //
    // -1.0 + (-2^-53)
    //
    // Expected:
    //   RNE -> -1.0
    //   RTZ -> -1.0
    //   RDN -> -1.0 - ULP
    //   RUP -> -1.0
    //   RMM -> -1.0 - ULP
    // ============================================================

    // RNE
    fpu_op(INST_FADD, 5'b00000, 3'b000, 1'b0, F64_NEG_ONE, 64'hBCA0000000000000);
    check(result, F64_NEG_ONE, "RM RNE neg tie");

    // RTZ
    fpu_op(INST_FADD, 5'b00000, 3'b001, 1'b0, F64_NEG_ONE, 64'hBCA0000000000000);
    check(result, F64_NEG_ONE, "RM RTZ neg tie");

    // RDN
    fpu_op(INST_FADD, 5'b00000, 3'b010, 1'b0, F64_NEG_ONE, 64'hBCA0000000000000);
    check(result, F64_NEG_ONE_MINUS_ULP, "RM RDN neg tie");

    // RUP
    fpu_op(INST_FADD, 5'b00000, 3'b011, 1'b0, F64_NEG_ONE, 64'hBCA0000000000000);
    check(result, F64_NEG_ONE, "RM RUP neg tie");

    // RMM
    fpu_op(INST_FADD, 5'b00000, 3'b100, 1'b0, F64_NEG_ONE, 64'hBCA0000000000000);
    check(result, F64_NEG_ONE_MINUS_ULP, "RM RMM neg tie");


    // ============================================================
    // Exact result should ignore RM
    // ============================================================

    for (int rm = 0; rm <= 4; rm++) begin
      fpu_op(INST_FADD, 5'b00000, rm[2:0], 1'b0, F64_1P5, F64_HALF);

      check(result, F64_TWO, $sformatf("RM exact result rm=%0d", rm));
    end
    ;


    // ============================================================
    // Overflow behavior depends on rounding mode
    // ============================================================

    // RNE -> +INF
    fpu_op(INST_FADD, 5'b00000, 3'b000, 1'b0, F64_MAX, F64_MAX);
    check(result, F64_INF_POS, "RM overflow RNE");

    // RTZ -> MAX_FINITE
    fpu_op(INST_FADD, 5'b00000, 3'b001, 1'b0, F64_MAX, F64_MAX);
    check(result, F64_MAX, "RM overflow RTZ");

    // RDN -> MAX_FINITE (positive result)
    fpu_op(INST_FADD, 5'b00000, 3'b010, 1'b0, F64_MAX, F64_MAX);
    check(result, F64_MAX, "RM overflow RDN");

    // RUP -> +INF
    fpu_op(INST_FADD, 5'b00000, 3'b011, 1'b0, F64_MAX, F64_MAX);
    check(result, F64_INF_POS, "RM overflow RUP");

    // RMM -> +INF
    fpu_op(INST_FADD, 5'b00000, 3'b100, 1'b0, F64_MAX, F64_MAX);
    check(result, F64_INF_POS, "RM overflow RMM");

    $display("--- FCLASS ---");

    inst      = INST_FCLASS;
    fp_fmt    = FP_FMT_D;
    operand_a = F64_ZERO;
    #1;

    check(result, 64'h10, "FCLASS +0");

    inst      = INST_FCLASS;
    operand_a = F64_NEG_ZERO;
    #1;

    check(result, 64'h08, "FCLASS -0");

    inst      = INST_FCLASS;
    operand_a = F64_INF_POS;
    #1;

    check(result, 64'h80, "FCLASS +INF");

    inst      = INST_FCLASS;
    operand_a = F64_INF_NEG;
    #1;

    check(result, 64'h001, "FCLASS -INF");

    $display("--- FCVT.S.D / FCVT.D.S ---");

    // D -> S
    inst      = INST_FCVT_SD;
    operand_a = F64_ONE;
    fp_rm     = 3'b000;
    #1;

    // Expected NaN-boxed single precision 1.0
    check(result, 64'hFFFF_FFFF_3F80_0000, "FCVT.S.D 1.0");

    // S -> D
    inst      = INST_FCVT_DS;
    operand_a = 64'hFFFF_FFFF_3F80_0000;
    fp_rm     = 3'b000;
    #1;

    check(result, F64_ONE, "FCVT.D.S 1.0");


    // FCVT — float↔int
    // fp_funct5[3] selects direction: 1=float-->int (11000=0x18), 0=int-->float (11010=0x1A)
    // operand_b[0] = cvt_word: 1=32-bit, 0=64-bit
    $display("--- FCVT ---");

    // FCVT.L.D: 2.0 --> int64 = 2  (float-->int, 64-bit, signed)
    fpu_cvt_op(1'b1, FP_FMT_D, 1'b0, 1'b1, F64_TWO);
    check(result, 64'd2, "FCVT.L.D 2.0-->2");

    test_num++;
    if (to_int) pass_count++;
    else begin
      fail_count++;
      $display("[FAIL] FCVT.L.D to_int should be 1");
    end

    // FCVT.L.D: -1.0 --> int64 = -1
    fpu_cvt_op(1'b1, FP_FMT_D, 1'b0, 1'b1, F64_NEG_ONE);
    check(result, 64'hFFFF_FFFF_FFFF_FFFF, "FCVT.L.D -1.0-->-1");

    // FCVT.W.D: 2.0 --> int32 = 2  (operand_b[0]=1 --> 32-bit)
    fpu_cvt_op(1'b1, FP_FMT_D, 1'b1, 1'b1, F64_TWO);
    check(result, 64'd2, "FCVT.W.D 2.0-->2");

    // FCVT.W.D: 2.0 --> int32 = 2  (operand_b[0]=1 --> 32-bit)
    fpu_cvt_op(1'b1, FP_FMT_D, 1'b1, 1'b1, F64_1P6666);
    check(result, 64'd1, "FCVT.W.D 1.6666-->1");

    // FCVT.D.L: int64 2 --> 2.0  (fp_funct5=5'b11010, bit3=1 but direction=0?)
    fpu_cvt_op(1'b0, FP_FMT_D, 1'b0, 1'b1, 64'd4);
    // 4 --> 4.0 expected: 0x4010000000000000
    check(result, F64_FOUR, "FCVT.D.L 4-->4.0");


    // FCVT BUG NOTE TEST
    // Verify to_int signal for CMP
    fpu_op(INST_FCMP, 5'b10100, 3'b010, 1'b0, F64_ONE, F64_ONE);
    test_num++;
    if (to_int) begin
      pass_count++;
      $display("[PASS] #%0d FCMP to_int=1 (result-->int regfile)", test_num);
    end else begin
      fail_count++;
      $display("[FAIL] #%0d FCMP to_int should be 1", test_num);
    end





    // Write result file  (matches tb_alu.sv exactly)
    $fdisplay(fd, "TEST_NAME=tb_fpu");
    $fdisplay(fd, "PASS=%0d", pass_count);
    $fdisplay(fd, "FAIL=%0d", fail_count);
    $fdisplay(fd, "TOTAL=%0d", test_num);

    if (fail_count == 0) $fdisplay(fd, "STATUS=PASS");
    else $fdisplay(fd, "STATUS=FAIL");

    $fclose(fd);

    $display("==== RESULT: PASS=%0d FAIL=%0d ====", pass_count, fail_count);

    if (fail_count == 0) $display("ALL PASS");
    else $fatal(1, "TEST FAILED");

    $finish;
  end

endmodule
