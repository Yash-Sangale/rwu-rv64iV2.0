
`timescale 1ns / 1ps

module tb_top_npl_sanity;


  // Test selection — change to 0 for ALU, 1 for FPU
  parameter int TEST_SEL = 0;
  parameter string IMEM_ALU     = "C:/Users/sanga/Documents/GitHub/RISC-V-64/RV64IFD/sw/asm/alu_sanity/out/alu_sanity.mem";
  parameter string DMEM_ALU     = "C:/Users/sanga/Documents/GitHub/RISC-V-64/RV64IFD/sw/asm/alu_sanity/out/alu_sanity.dmem";
  parameter string IMEM_FPU     = "C:/Users/sanga/Documents/GitHub/RISC-V-64/RV64IFD/sw/asm/fpu_sanity/out/fpu_sanity.mem";
  parameter string DMEM_FPU     = "C:/Users/sanga/Documents/GitHub/RISC-V-64/RV64IFD/sw/asm/fpu_sanity/out/fpu_sanity.dmem";
  parameter int TIMEOUT_CYC = 100_000; // spin loop detectoin logic there

  // Derived: pick IMEM/DMEM based on TEST_SEL
  // (SV doesn't allow ternary on string params directly — use `ifdef or just
  //  instantiate with the right string. We use a generate-friendly approach.)
  localparam string IMEM_FILE = (TEST_SEL == 0) ? IMEM_ALU : IMEM_FPU;

  localparam string DMEM_FILE = (TEST_SEL == 0) ? DMEM_ALU : DMEM_FPU;

  localparam string TEST_NAME = (TEST_SEL == 0) ? "alu_sanity" : "fpu_sanity";


  // Clock / Reset

  localparam real CLK_PERIOD = 12.5;  // 80 MHz
  logic clk = 0;
  always #(CLK_PERIOD / 2.0) clk = ~clk;

  logic rst_n = 0;
  initial begin
    repeat (8) @(posedge clk);
    rst_n = 1;
  end


  // DUT
  logic [31:0] gpio_out, gpio_oe;
  logic uart_tx;

  top_npl #(
      .IMEM_INIT(IMEM_FILE),
      .DMEM_INIT(DMEM_FILE)
  ) dut (
      .clk     (clk),
      .rst_n   (rst_n),
      .gpio_in (32'b0),
      .gpio_out(gpio_out),
      .gpio_oe (gpio_oe),
      .uart_tx (uart_tx),
      .uart_rx (1'b1)
  );


  // Internal signal aliases (for readability — no new logic, just naming)
  // All paths go through dut.* hierarchy

  // State enum values — must match top_npl typedef
  // FETCH0_ST=0, FETCH1_ST=1, EXEC_ST=2, EXECLD_ST=3

  function automatic string state_str(input logic [1:0] s);
    case (s)
      2'd0: state_str = "FETCH0";
      2'd1: state_str = "FETCH1";
      2'd2: state_str = "EXEC  ";
      2'd3: state_str = "EXECLD";
      default: state_str = "??    ";
    endcase
  endfunction


  // Memory init check (after reset releases)
  initial begin
    @(posedge rst_n);
    @(posedge clk);
    $display("=== MEMORY INIT CHECK ===");
    $display("IMEM[0]  = %08h", dut.u_imem.mem[0]);
    $display("IMEM[1]  = %08h", dut.u_imem.mem[1]);
    $display("IMEM[2]  = %08h", dut.u_imem.mem[2]);
    $display("IMEM[3]  = %08h", dut.u_imem.mem[3]);
    if (TEST_SEL == 1) begin
      $display("DMEM[0]  = %016h  (expect 3FF0000000000000 = 1.0)", dut.u_dmem.mem[0]);
      $display("DMEM[1]  = %016h  (expect 4000000000000000 = 2.0)", dut.u_dmem.mem[1]);
      $display("DMEM[2]  = %016h  (expect 4010000000000000 = 4.0)", dut.u_dmem.mem[2]);
    end
    $display("=========================\n");
  end


  // Cycle trace logger
  always @(posedge clk) begin
    if (rst_n) begin
      $display("[%6t ns] [%s] PC=%016h IR=%08h commit=%b valid=%b", $time, state_str(dut.state_r),
               dut.pc_r, dut.ir_r, dut.instr_commit, dut.ir_valid_r);

      // Integer writeback
      if (dut.int_we) $display("           [WB INT] x%02d <= %016h", dut.dec.rd, dut.wb_data);

      // FP writeback
      if (dut.fp_we) $display("           [WB FPU] f%02d <= %016h", dut.dec.rd, dut.fp_wb_data);

      // Trap
      if (dut.trap_taken)
        $display(
            "           [TRAP] cause=%016h mepc=%016h -> mtvec=%016h",
            dut.trap_cause,
            dut.mepc,
            dut.mtvec
        );
    end
  end


  logic [63:0] prev_pc;
  int          same_pc_count;
  logic        spin_detected;
  assign spin_detected = 1'b0;  // driven procedurally below

  logic spin_seen;
  int   spin_iterations;


  // Spin-loop detector and final checker
  initial begin
    prev_pc         = '1;
    same_pc_count   = 0;
    spin_seen       = 0;
    spin_iterations = 0;


    @(posedge rst_n);

    forever begin
      @(posedge clk);
      if (rst_n && dut.fetch0_ph) begin
        if (!spin_seen) begin
          if (dut.pc_r == prev_pc) begin
            same_pc_count++;
            if (same_pc_count == 3) begin
              spin_seen = 1;
              $display("\nSpin loop detected @ PC=%016h", dut.pc_r);
            end
          end else begin
            same_pc_count = 0;
            prev_pc       = dut.pc_r;
          end
        end else begin
          spin_iterations++;
          if (spin_iterations == 5) begin
            $display("\nSpin loop executed %0d iterations", spin_iterations);
            run_checks();
            $finish;
          end
        end
      end
    end
  end


  // Check task — called once spin loop is confirmed
  task automatic run_checks();

    int pass_count;
    int fail_count;

    pass_count = 0;
    fail_count = 0;

    if (TEST_SEL == 0) begin

      $display("\n--- ALU SANITY CHECK ---");

      check_ireg(3, 64'd125, "x3  ADD", pass_count, fail_count);
      check_ireg(4, 64'd75, "x4  SUB", pass_count, fail_count);

      check_ireg(5, 64'd0, "x5  AND", pass_count, fail_count);
      check_ireg(6, 64'd125, "x6  OR", pass_count, fail_count);
      check_ireg(7, 64'd125, "x7  XOR", pass_count, fail_count);

      check_ireg(9, 64'd33554432, "x9  SLL", pass_count, fail_count);

      check_ireg(11, -64'd32, "x11 SRA", pass_count, fail_count);

      check_ireg(13, 64'd32, "x13 SRL", pass_count, fail_count);

      check_ireg(14, 64'd1, "x14 SLT", pass_count, fail_count);
      check_ireg(15, 64'd0, "x15 SLT", pass_count, fail_count);

      check_ireg(16, 64'd1, "x16 SLTU", pass_count, fail_count);
      check_ireg(17, 64'd0, "x17 SLTU", pass_count, fail_count);

      check_ireg(19, 64'd125, "x19 LD", pass_count, fail_count);

      check_ireg(20, 64'd200, "x20 DEP1", pass_count, fail_count);
      check_ireg(21, 64'd225, "x21 DEP2", pass_count, fail_count);
      check_ireg(22, 64'd226, "x22 DEP3", pass_count, fail_count);

    end else begin

      $display("\n--- FPU SANITY CHECK ---");


      // FP arithmetic
      check_freg(10, 64'h4008000000000000, "f10 FADD", pass_count, fail_count);

      check_freg(11, 64'h4000000000000000, "f11 FSUB", pass_count, fail_count);

      check_freg(12, 64'h4010000000000000, "f12 FMUL", pass_count, fail_count);

      check_freg(13, 64'h4000000000000000, "f13 FDIV", pass_count, fail_count);

      check_freg(14, 64'h4000000000000000, "f14 FSQRT", pass_count, fail_count);


      // Sign inject
      check_freg(15, 64'hBFF0000000000000, "f15 FSGNJ", pass_count, fail_count);

      check_freg(16, 64'h3FF0000000000000, "f16 FSGNJN", pass_count, fail_count);

      check_freg(17, 64'hBFF0000000000000, "f17 FSGNJX", pass_count, fail_count);


      // Min / Max
      check_freg(18, 64'hBFF0000000000000, "f18 FMIN", pass_count, fail_count);

      check_freg(19, 64'h4000000000000000, "f19 FMAX", pass_count, fail_count);


      // Conversions
      check_freg(20, 64'h4010000000000000, "f20 FCVT.D.L", pass_count, fail_count);


      // Store reload
      check_freg(21, 64'h4008000000000000, "f21 FLD/FSD", pass_count, fail_count);

      check_freg(22, 64'h4010000000000000, "f22 FLD/FSD", pass_count, fail_count);


      // Integer results
      check_ireg(20, 64'd1, "x20 FEQ", pass_count, fail_count);

      check_ireg(21, 64'd1, "x21 FLT", pass_count, fail_count);

      check_ireg(22, 64'd1, "x22 FLE", pass_count, fail_count);

      check_ireg(23, 64'h4008000000000000, "x23 FMV.X.D", pass_count, fail_count);

      check_ireg(25, 64'd4, "x25 FCVT.L.D", pass_count, fail_count);

      check_ireg(26, 64'h40, "x26 FCLASS", pass_count, fail_count);
    end

    $display("\n==================================================");
    $display("RESULT: %0d PASSED, %0d FAILED", pass_count, fail_count);

    if (fail_count == 0) $display(">>> ALL CHECKS PASSED <<<");
    else $display(">>> FAILURES DETECTED <<<");

    $display("==================================================\n");

  endtask

  task automatic check_ireg(input int reg_idx, input logic [63:0] expected, input string label,
                            ref int pass_count, ref int fail_count);
    logic [63:0] actual;
    actual = dut.u_irf.regs[reg_idx];
    if (actual === expected) begin
      $display("  PASS  %s  got=%016h", label, actual);
      pass_count++;
    end else begin
      $display("  FAIL  %s  got=%016h  exp=%016h", label, actual, expected);
      fail_count++;
    end
  endtask

  task automatic check_freg(input int reg_idx, input logic [63:0] expected, input string label,
                            ref int pass_count, ref int fail_count);
    logic [63:0] actual;
    actual = dut.u_frf.regs[reg_idx];
    if (actual === expected) begin
      $display("  PASS  %s  got=%016h", label, actual);
      pass_count++;
    end else begin
      $display("  FAIL  %s  got=%016h  exp=%016h", label, actual, expected);
      fail_count++;
    end
  endtask


  // Watchdog
  initial begin
    repeat (TIMEOUT_CYC) @(posedge clk);
    $display("\n[%0t ns] TIMEOUT — spin loop never reached. Last PC = %016h", $time, dut.pc_r);
    $display("Last IR = %08h  state = %s  valid = %b", dut.ir_r, state_str(dut.state_r),
             dut.ir_valid_r);
    $finish;
  end

endmodule
