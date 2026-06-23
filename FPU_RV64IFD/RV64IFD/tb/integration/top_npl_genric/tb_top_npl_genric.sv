// =============================================================================
// tb_top_npl.sv — Generic Verification Testbench
// =============================================================================

`timescale 1ns / 1ps

module tb_top_npl_genric;

  // @todo Pass these from your Makefile/Simulator command line
  // e.g., vsim -gIMEM_FILE="path/to/test.mem" -gDMEM_FILE="path/to/test.dmem"
  parameter string IMEM_FILE = "C:/Users/sanga/Documents/GitHub/RISC-V-64/RV64IFD/sw/asm/genric/fpu_basic/out/fpu_basic.mem";
  parameter string DMEM_FILE = "C:/Users/sanga/Documents/GitHub/RISC-V-64/RV64IFD/sw/asm/genric/fpu_basic/out/fpu_basic.dmem";
  parameter string TEST_NAME = "fpu_basic";
  
  parameter int TIMEOUT_CYC = 500;

  localparam real CLK_PERIOD = 12.5;  // 80 MHz
  logic clk = 0;
  always #(CLK_PERIOD / 2.0) clk = ~clk;

  int    fd;
  string result_file;
  logic rst_n = 0;

  initial begin
    if (!$value$plusargs("RESULT_FILE=%s", result_file))
      result_file = {$sformatf("%m"), "_result.txt"};
    fd = $fopen(result_file, "w");

    repeat (10) @(posedge clk);
    rst_n = 1;
  end

  // DUT Instantiation
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

  // State String Helper
  function automatic string state_str(input logic [1:0] s);
    case (s)
      2'd0: state_str = "FETCH0";
      2'd1: state_str = "FETCH1";
      2'd2: state_str = "EXEC  ";
      2'd3: state_str = "EXECLD";
      default: state_str = "??    ";
    endcase
  endfunction

  // Cycle trace logger
  always @(posedge clk) begin
    if (rst_n) begin
      $display("[%6t ns] [%s] PC=%016h IR=%08h", $time, state_str(dut.state_r), dut.pc_r, dut.ir_r);
      if (dut.int_we) $display("           [WB INT] x%02d <= %016h", dut.dec.rd, dut.wb_data);
      if (dut.fp_we)  $display("           [WB FPU] f%02d <= %016h", dut.dec.rd, dut.fp_wb_data);
    end
  end

  // Spin-loop detector
  logic [63:0] prev_pc;
  int          same_pc_count;

  initial begin
    prev_pc       = 64'hFFFF_FFFF_FFFF_FFFF;
    same_pc_count = 0;

    @(posedge rst_n);

    forever begin
      @(posedge clk);
      if (rst_n && dut.fetch0_ph) begin
        if (dut.pc_r == prev_pc) begin
          same_pc_count++;
          if (same_pc_count == 3) begin
            $display("\n==================================================");
            $display("SPIN LOOP DETECTED at PC = %016h", dut.pc_r);
            $display("TEST COMPLETION: %s", TEST_NAME);
            $display("==================================================");
            run_checks();
            $finish;
          end
        end else begin
          same_pc_count = 0;
          prev_pc = dut.pc_r;
        end
      end
    end
  end

  // Check task — Reads x10 (a0) to determine PASS/FAIL
  task automatic run_checks();
    logic [63:0] exit_code;
    
    // Read register x10 (a0 in ABI)
    exit_code = dut.u_irf.regs[10];

    if (exit_code === 64'd0) begin
      $display(">>> TEST PASSED <<< (x10 = 0)");
      $fdisplay(fd, "STATUS=PASS");
    end else begin
      $display(">>> TEST FAILED <<< (x10 = %0d)", exit_code);
      $fdisplay(fd, "STATUS=FAIL");
    end
    $fclose(fd);
    $display("==================================================\n");
  endtask

  // Watchdog
  initial begin
    repeat (TIMEOUT_CYC) @(posedge clk);
    $display("\n[%0t ns] TIMEOUT — Test did not complete.", $time);
    $fdisplay(fd, "STATUS=FAIL (TIMEOUT)");
    $finish;
  end

endmodule