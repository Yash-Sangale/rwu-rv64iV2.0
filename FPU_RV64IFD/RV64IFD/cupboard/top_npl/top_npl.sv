`timescale 1ns / 1ps

`ifndef TOP_NPL_SV
`define TOP_NPL_SV 

`include "isa_pkg.sv"
`include "types_pkg.sv"
`include "wb_pkg.sv"
`include "mem_map_pkg.sv"

import isa_pkg::*;
import pkg_fpu_types::*;
import types_pkg::*;
import wb_pkg::*;
import mem_map_pkg::*;

module top_npl #(
    parameter string IMEM_INIT_FILE = "",
    parameter string DMEM_INIT_FILE = "",
    parameter int    CLK_FREQ_HZ    = 80_000_000,
    parameter int    BAUD_RATE      = 115_200
) (
    input logic clk,
    input logic rst_n,

    output logic uart_tx,
    input  logic uart_rx,

    inout tri [31:0] gpio_io,

    output logic cs_o
);

  // =========================================================================
  // FSM States
  // =========================================================================
  typedef enum logic [1:0] {
    ST_FETCH0,
    ST_FETCH1,
    ST_EXEC,
    ST_EXECLD
  } state_t;

  state_t state_r, state_next;

  // Master Phase Identifiers
  logic fetch0_ph, fetch1_ph, exec_ph, execld_ph;
  assign fetch0_ph = (state_r == ST_FETCH0);
  assign fetch1_ph = (state_r == ST_FETCH1);
  assign exec_ph   = (state_r == ST_EXEC);
  assign execld_ph = (state_r == ST_EXECLD);

  // =========================================================================
  // Instruction Register & Control Flow Registers
  // =========================================================================
  logic [ILEN-1:0] ir_r;
  logic            ir_valid_r;
  logic [     6:0] opcode_ir;

  assign opcode_ir = ir_r[6:0];

  logic [XLEN-1:0] pc_r, pc_plus4;
  assign pc_plus4 = pc_r + 64'd4;

  // Registered Target Flags to bridge across cycles safely
  logic                      branch_taken_r;
  logic           [XLEN-1:0] branch_target_r;
  logic                      mret_pending_r;
  logic                      trap_taken_r;

  // =========================================================================
  // Decoder Setup
  // =========================================================================
  decoded_instr_t            dec;
  logic                      dec_illegal;

  ins_decoder u_dec (
      .instr  (ir_r),
      .dec    (dec),
      .illegal(dec_illegal)
  );

  // =========================================================================
  // Memory Operation Qualification (Fixes Truncated Memory Cycles)
  // =========================================================================
  logic is_mem_op;
  logic is_dmem_access, is_periph_access;
  logic is_load_op;

  // Qualify across both active execution phases
  assign is_load_op = ((opcode_ir == OP_LOAD) || (opcode_ir == OP_LOAD_FP));
  assign is_mem_op  = ir_valid_r && (exec_ph || execld_ph) && (dec.mem_read || dec.mem_write);

  // Isolate execution logic from writeback variables using ALU results directly
  logic [XLEN-1:0] alu_result;
  assign is_dmem_access   = is_mem_op && in_dmem(alu_result);
  assign is_periph_access = is_mem_op && in_periph(alu_result);

  // Synchronous Acknowledgment Termination Handshake
  logic dmem_ack_s;
  wb_resp_t dbus_resp;
  logic load_done;

  assign load_done = (is_dmem_access && dmem_ack_s) || (is_periph_access && dbus_resp.ack);

  // =========================================================================
  // FSM Logic Loop
  // =========================================================================
  // =========================================================================
  // FSM Logic Loop (Defended against 'X' Propagation hazards)
  // =========================================================================
  always_comb begin
    state_next = state_r;
    unique case (state_r)
      ST_FETCH0: state_next = ST_FETCH1;
      ST_FETCH1: state_next = ST_EXEC;
      ST_EXEC:   state_next = (is_load_op && ir_valid_r) ? ST_EXECLD : ST_FETCH0;
      ST_EXECLD: begin
        if (load_done === 1'b1) state_next = ST_FETCH0;
        else if (load_done === 1'b0) state_next = ST_EXECLD;
        else state_next = ST_EXECLD;  // Default fallback protects against 1'bx
      end
      default:   state_next = ST_FETCH0;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) state_r <= ST_FETCH0;
    else state_r <= state_next;
  end

  // Instruction Retirement Gate
  logic instr_commit;
  assign instr_commit = ((exec_ph && !is_load_op) || (execld_ph && load_done)) && ir_valid_r;

  // =========================================================================
  // Program Counter Update Logic (Aligned with Professor Core)
  // =========================================================================
  logic [XLEN-1:0] mtvec, mepc;
  logic trap_taken;  // From trap controller

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pc_r         <= '0;
      trap_taken_r <= 1'b0;
    end else begin
      if (fetch0_ph) begin
        trap_taken_r <= 1'b0;  // Reset latch
        if (trap_taken || trap_taken_r) begin
          pc_r <= {mtvec[XLEN-1:2], 2'b00};
        end else if (mret_pending_r) begin
          pc_r <= mepc;
        end else if (branch_taken_r) begin
          pc_r <= branch_target_r;
        end else begin
          pc_r <= pc_r + 4;
        end
      end else if (exec_ph && trap_taken) begin
        trap_taken_r <= 1'b1;  // Latch if trap breaks in late during exec
      end
    end
  end

  // =========================================================================
  // Instruction Fetch & Latching Engine
  // =========================================================================
  logic [ILEN-1:0] imem_rdata;
  logic            imem_valid;

  i_mem #(
      .INIT_FILE(IMEM_INIT_FILE),
      .PARITY_EN(1)
  ) u_imem (
      .clk       (clk),
      .rst_n     (rst_n),
      .cs        (fetch0_ph || fetch1_ph),
      .addr      (pc_r),
      .rdata     (imem_rdata),
      .valid     (imem_valid),
      .parity_err(),
      .jtag_we   (1'b0),
      .jtag_addr ('0),
      .jtag_wdata('0)
  );

  logic is_mret;
  assign is_mret = (ir_r[6:0]   == 7'b111_0011) &&
                   (ir_r[14:12] == 3'b000)       &&
                   (ir_r[31:20] == 12'h302);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ir_r           <= 32'h0000_0013;  // Inject Hard NOP
      ir_valid_r     <= 1'b0;
      mret_pending_r <= 1'b0;
    end else if (fetch1_ph) begin
      if (!mret_pending_r) begin
        ir_r       <= imem_rdata;
        ir_valid_r <= imem_valid;
      end else begin
        ir_r           <= 32'h0000_0013;
        ir_valid_r     <= 1'b0;
        mret_pending_r <= 1'b0;  // Cleared on fetch injection
      end
    end else if (exec_ph) begin
      if (is_mret && ir_valid_r) begin
        mret_pending_r <= 1'b1;
        ir_r           <= 32'h0000_0013;  // Flush IR
        ir_valid_r     <= 1'b0;
      end else if (trap_taken) begin
        ir_r       <= 32'h0000_0013;  // Trap flush
        ir_valid_r <= 1'b0;
      end
    end
  end

  // =========================================================================
  // Register Files & Operand Selection
  // =========================================================================
  logic [XLEN-1:0] int_rs1_val, int_rs2_val;
  logic [XLEN-1:0] fp_rs1_val, fp_rs2_val;
  logic [XLEN-1:0] rs1_val, rs2_val;
  logic rf_we, frf_we;
  logic [4:0] rf_waddr, frf_waddr;
  logic [XLEN-1:0] rf_wdata, frf_wdata;

  i_regfile #(
      .ASYNC_READ(1'b1)
  ) u_rf (
      .clk(clk),
      .rst_n(rst_n),
      .rs1_addr(dec.rs1),
      .rs1_data(int_rs1_val),
      .rs2_addr(dec.rs2),
      .rs2_data(int_rs2_val),
      .rd_addr(rf_waddr),
      .rd_data(rf_wdata),
      .rd_we(rf_we)
  );

  f_regfile #(
      .ASYNC_READ(1'b1)
  ) u_frf (
      .clk(clk),
      .rst_n(rst_n),
      .rs1_addr(dec.rs1),
      .rs1_data(fp_rs1_val),
      .rs2_addr(dec.rs2),
      .rs2_data(fp_rs2_val),
      .rd_addr(frf_waddr),
      .rd_data(frf_wdata),
      .rd_we(frf_we)
  );

  always_comb begin
    rs1_val = int_rs1_val;
    rs2_val = int_rs2_val;
    unique case (dec.instruction)
      INST_FADD, INST_FSUB, INST_FMUL, INST_FDIV,
      INST_FSQRT, INST_FSGNJ, INST_FMINMAX,
      INST_FCMP, INST_FCVT_DS, INST_FCVT_SD: begin
        rs1_val = fp_rs1_val;
        rs2_val = fp_rs2_val;
      end
      INST_FMVXW, INST_FMVXD, INST_FCLASS, INST_FCVT: begin
        rs1_val = fp_rs1_val;
        rs2_val = int_rs2_val;
      end
      INST_FMVWX, INST_FMVDX: begin
        rs1_val = int_rs1_val;
        rs2_val = fp_rs2_val;
      end
      default: begin
        rs1_val = int_rs1_val;
        rs2_val = dec.fp_store ? fp_rs2_val : int_rs2_val;
      end
    endcase
  end

  // =========================================================================
  // Execution Core (ALU & FPU Engine)
  // =========================================================================
  logic [XLEN-1:0] alu_a, alu_b;
  logic alu_flag_eq, alu_flag_lt_s, alu_flag_lt_u;

  always_comb begin
    alu_a = rs1_val;
    if (dec.opcode == OP_AUIPC) alu_a = pc_r;
    if (dec.opcode == OP_LUI) alu_a = '0;
    alu_b = dec.alu_src ? dec.imm : rs2_val;
  end

  alu_top u_alu (
      .inst(dec.instruction),
      .operand_a(alu_a),
      .operand_b(alu_b),
      .result(alu_result),
      .zero(),
      .negative(),
      .overflow(),
      .carry(),
      .flag_eq(alu_flag_eq),
      .flag_lt_s(alu_flag_lt_s),
      .flag_lt_u(alu_flag_lt_u),
      .clk(clk),
      .rst_n(rst_n),
      .muldiv_valid_in(exec_ph),
      .muldiv_ready(),
      .muldiv_valid_out()
  );

  logic [XLEN-1:0] fpu_result;
  logic [     4:0] fpu_fflags;
  logic [     2:0] frm_value;
  logic            is_pure_fp_math;

  always_comb begin
    if ((dec.opcode == OP_FP) || (dec.opcode == 7'b1000011) || 
        (dec.opcode == 7'b1000111) || (dec.opcode == 7'b1001011) || 
        (dec.opcode == 7'b1001111)) begin
      if ((dec.instruction == INST_FLD) || (dec.instruction == INST_FLW) ||
          (dec.instruction == INST_FSD) || (dec.instruction == INST_FSW) ||
          (dec.instruction == INST_NOP)) begin
        is_pure_fp_math = 1'b0;
      end else begin
        is_pure_fp_math = 1'b1;
      end
    end else begin
      is_pure_fp_math = 1'b0;
    end
  end

  fpu_top u_fpu (
      .clk(clk),
      .rst_n(rst_n),
      .inst((is_pure_fp_math ? dec.instruction : INST_NOP)),
      .fp_funct5(dec.fp_funct5),
      .fp_rm((dec.fp_rm == 3'b111) ? frm_value : dec.fp_rm),
      .fp_fmt(dec.fp_fmt),
      .fp_sgn_op(dec.fp_sgn_op),
      .fp_min_sel(dec.fp_min_sel),
      .fp_cvt_toint(dec.fp_cvt_toint),
      .fp_cvt_word(dec.fp_cvt_word),
      .fp_cvt_signed(dec.fp_cvt_signed),
      .operand_a(rs1_val),
      .operand_b(rs2_val),
      .int_operand(int_rs1_val),
      .result(fpu_result),
      .to_int(),
      .fflags(fpu_fflags),
      .div_valid_in(exec_ph && ir_valid_r && (dec.instruction == INST_FDIV)),
      .div_ready(),
      .div_valid_out()
  );



  // =========================================================================
  // Branch & Jump Evaluation Engine
  // =========================================================================
  logic            branch_taken;
  logic [XLEN-1:0] branch_target;

  always_comb begin
    branch_taken  = 1'b0;
    branch_target = pc_r + $signed(dec.imm);

    if (exec_ph && ir_valid_r) begin
      if (dec.jal) begin
        branch_taken = 1'b1;
      end else if (dec.jalr) begin
        branch_taken  = 1'b1;
        branch_target = (rs1_val + dec.imm) & ~64'h1;
      end else if (dec.branch) begin
        unique case (dec.funct3)
          3'b000:  branch_taken = alu_flag_eq;
          3'b001:  branch_taken = !alu_flag_eq;
          3'b100:  branch_taken = alu_flag_lt_s;
          3'b101:  branch_taken = !alu_flag_lt_s;
          3'b110:  branch_taken = alu_flag_lt_u;
          3'b111:  branch_taken = !alu_flag_lt_u;
          default: branch_taken = 1'b0;
        endcase
      end
    end
  end

  // Bridge control choices safely to the next clock edge
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      branch_taken_r  <= 1'b0;
      branch_target_r <= '0;
    end else if (exec_ph && ir_valid_r) begin
      branch_taken_r  <= branch_taken;
      branch_target_r <= branch_target;
    end else if (fetch0_ph) begin
      branch_taken_r <= 1'b0;
    end
  end

  // Address Alignment Monitor
  logic addr_misaligned;
  always_comb begin
    addr_misaligned = 1'b0;
    if (ir_valid_r && exec_ph) begin
      if (dec.mem_read || dec.mem_write) begin
        unique case (dec.funct3)
          3'b001, 3'b101: addr_misaligned = alu_result[0];
          3'b010, 3'b110: addr_misaligned = |alu_result[1:0];
          3'b011:         addr_misaligned = |alu_result[2:0];
          default:        addr_misaligned = 1'b0;
        endcase
      end
      if (((dec.branch && branch_taken) || dec.jal || dec.jalr) && (branch_target[1:0] != 2'b00)) begin
        addr_misaligned = 1'b1;
      end
    end
  end

  // =========================================================================
  // Wishbone Master Interface System (Clean Data Bus Integration)
  // =========================================================================
  logic [7:0] dmem_sel_s;
  function automatic logic [7:0] funct3_sel(input logic [2:0] f3, input logic [2:0] lsb);
    unique case (f3)
      3'b000, 3'b100: return 8'b0000_0001 << lsb;
      3'b001, 3'b101: return 8'b0000_0011 << {lsb[2:1], 1'b0};
      3'b010, 3'b110: return 8'b0000_1111 << {lsb[2], 2'b00};
      3'b011:         return 8'b1111_1111;
      default:        return 8'b0;
    endcase
  endfunction

  assign dmem_sel_s = funct3_sel(dec.funct3, alu_result[2:0]);

  // Dedicated RAM Block Interface
  logic [XLEN-1:0] dmem_rdata_s;
  d_mem #(
      .INIT_FILE(DMEM_INIT_FILE),
      .FWD_EN(1),
      .PARITY_EN(1)
  ) u_dmem (
      .clk(clk),
      .rst_n(rst_n),
      .cs(is_dmem_access),
      .we(dec.mem_write),
      .addr(alu_result),
      .sel(dmem_sel_s),
      .wdata(rs2_val),
      .rdata(dmem_rdata_s),
      .ack(dmem_ack_s),
      .parity_err(),
      .dbg_addr('0),
      .dbg_rdata()
  );

  // Peripheral Interconnect Requests
  wb_req_t dbus_req;
  always_comb begin
    dbus_req = WB_REQ_IDLE;
    if (is_periph_access) begin
      dbus_req.cyc = 1'b1;
      dbus_req.stb = 1'b1;
      dbus_req.we  = dec.mem_write;
      dbus_req.adr = alu_result;
      dbus_req.dat = rs2_val;
      dbus_req.sel = dmem_sel_s;
    end
  end

  // Data Normalization & Formatting Multiplexers
  logic [XLEN-1:0] raw_rdata, load_data;
  assign raw_rdata = is_dmem_access ? dmem_rdata_s : dbus_resp.dat;

  always_comb begin
    logic [ 7:0] bl;
    logic [15:0] hl;
    logic [31:0] wl;
    bl = raw_rdata >> ({alu_result[2:0], 3'b0});
    hl = raw_rdata >> ({alu_result[2:1], 4'b0});
    wl = raw_rdata >> ({alu_result[2], 5'b0});

    if (dec.fp_load) begin
      unique case (dec.funct3)
        3'b010:  load_data = fp_box_single(wl);
        3'b011:  load_data = raw_rdata;
        default: load_data = raw_rdata;
      endcase
    end else begin
      unique case (dec.funct3)
        3'b000:  load_data = {{56{bl[7]}}, bl};
        3'b001:  load_data = {{48{hl[15]}}, hl};
        3'b010:  load_data = {{32{wl[31]}}, wl};
        3'b011:  load_data = raw_rdata;
        3'b100:  load_data = {56'b0, bl};
        3'b101:  load_data = {48'b0, hl};
        3'b110:  load_data = {32'b0, wl};
        default: load_data = raw_rdata;
      endcase
    end
  end

  // =========================================================================
  // CSR Engine & Result Multiplexing
  // =========================================================================
  logic            is_csr;
  logic [XLEN-1:0] csr_rdata;
  assign is_csr = ir_valid_r && exec_ph && (dec.opcode == OP_SYSTEM) && (dec.funct3 != 3'b000);

  logic [XLEN-1:0] result_v;
  always_comb begin
    unique case (dec.opcode)
      OP_LOAD, OP_LOAD_FP: result_v = execld_ph ? load_data : alu_result;
      OP_JAL, OP_JALR:     result_v = pc_plus4;
      OP_SYSTEM:           result_v = csr_rdata;
      OP_FP:               result_v = fpu_result;
      default:             result_v = alu_result;
    endcase
  end

  // =========================================================================
  // Register File Write Data Direct Routing Assignments
  // =========================================================================
  assign rf_wdata  = result_v;
  assign frf_wdata = result_v;

  // =========================================================================
  // Gated Structural Register Writeback Control (2-Cycle Latency Safe)
  // =========================================================================
  logic [4:0] wb_rd_r;
  logic       wb_writes_int_r;
  logic       wb_writes_fp_r;

  // 1. Capture the exact structural destination intents during the EXEC phase
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wb_rd_r         <= '0;
      wb_writes_int_r <= 1'b0;
      wb_writes_fp_r  <= 1'b0;
    end else if (exec_ph) begin
      wb_rd_r <= dec.rd;
      wb_writes_int_r <= !dec.fp_load && !(dec.instruction inside {
        INST_FADD, INST_FSUB, INST_FMUL, INST_FDIV, INST_FSQRT, INST_FSGNJ, 
        INST_FMINMAX, INST_FCVT_DS, INST_FCVT_SD, INST_FMVWX, INST_FMVDX
      }) && dec.reg_write;

      wb_writes_fp_r  <= (dec.fp_load || (dec.instruction inside {
        INST_FADD, INST_FSUB, INST_FMUL, INST_FDIV, INST_FSQRT, INST_FSGNJ, 
        INST_FMINMAX, INST_FCVT_DS, INST_FCVT_SD, INST_FMVWX, INST_FMVDX
      }) || (dec.instruction == INST_FCVT && !dec.fp_cvt_toint)) && dec.reg_write;
    end

  end

  // 2. Route destination and write-enables based on the execution phase
  assign rf_waddr = execld_ph ? wb_rd_r : dec.rd;
  assign frf_waddr = execld_ph ? wb_rd_r : dec.rd;

  // 3. Gate the actual write-assertion execution with load completeness
  assign rf_we     = !trap_taken && (rf_waddr != 5'd0) && (
                     (exec_ph    && !is_load_op && dec.reg_write && !wb_writes_fp_r) || 
                     (execld_ph  && load_done   && wb_writes_int_r)
                   );

  assign frf_we    = !trap_taken && (frf_waddr != 5'd0) && (
                     (exec_ph    && !is_load_op && dec.reg_write && wb_writes_fp_r) || 
                     (execld_ph  && load_done   && wb_writes_fp_r)
                   );

  // =========================================================================
  // Wishbone Interconnect & Peripheral Layout
  // =========================================================================
  wb_req_t uart_req, gpio_req, qspi_req, irq_req, clk_req, jtag_req;
  wb_resp_t uart_resp, gpio_resp, qspi_resp, irq_resp, clk_resp, jtag_resp;

  assign qspi_resp = WB_RESP_IDLE;
  assign jtag_resp = WB_RESP_IDLE;

  wb_intercon u_intercon (
      .clk(clk),
      .rst_n(rst_n),
      .m_req(dbus_req),
      .m_resp(dbus_resp),
      .uart_req(uart_req),
      .uart_resp(uart_resp),
      .gpio_req(gpio_req),
      .gpio_resp(gpio_resp),
      .qspi0_req(qspi_req),
      .qspi0_resp(qspi_resp),
      .irq_req(irq_req),
      .irq_resp(irq_resp),
      .clk_req(clk_req),
      .clk_resp(clk_resp),
      .jtag_req(jtag_req),
      .jtag_resp(jtag_resp)
  );

  logic irq_uart_s, irq_gpio, irq_to_core;
  uart0 #(
      .CLK_FREQ_HZ(CLK_FREQ_HZ),
      .BAUD_RATE  (BAUD_RATE)
  ) u_uart (
      .clk(clk),
      .rst_n(rst_n),
      .wb_req(uart_req),
      .wb_resp(uart_resp),
      .tx(uart_tx),
      .rx(uart_rx),
      .irq(irq_uart_s)
  );

  logic [31:0] gpio_in_s, gpio_out_s, gpio_oe_s;
  genvar gi;
  generate
    for (gi = 0; gi < 32; gi++) begin : gpio_pad
      assign gpio_io[gi]   = gpio_oe_s[gi] ? gpio_out_s[gi] : 1'bz;
      assign gpio_in_s[gi] = gpio_io[gi];
    end
  endgenerate

  gpio u_gpio (
      .clk(clk),
      .rst_n(rst_n),
      .wb_req(gpio_req),
      .wb_resp(gpio_resp),
      .gpio_in(gpio_in_s),
      .gpio_out(gpio_out_s),
      .gpio_oe(gpio_oe_s),
      .irq(irq_gpio)
  );

  assign cs_o = gpio_req.cyc && gpio_req.stb;

  irq_ctrl #(
      .N_IRQ(8)
  ) u_irqctl (
      .clk(clk),
      .rst_n(rst_n),
      .wb_req(irq_req),
      .wb_resp(irq_resp),
      .irq_src({6'b0, irq_gpio, irq_uart_s}),
      .irq_out(irq_to_core),
      .irq_vec()
  );

  clk_ctrl u_clkctl (
      .clk(clk),
      .rst_n(rst_n),
      .wb_req(clk_req),
      .wb_resp(clk_resp),
      .clk_core(),
      .clk_bus(),
      .clk_qspi()
  );

  // =========================================================================
  // Co-Proherent Cores (CSR & Trap Handlers)
  // =========================================================================
  logic [XLEN-1:0] trap_cause_v, trap_pc_v;
  logic mret_taken, irq_pending, mie_global;

  csr_regfile u_csr (
      .clk(clk),
      .rst_n(rst_n),
      .csr_en(is_csr),
      .csr_addr(ir_r[31:20]),
      .csr_funct3(dec.funct3),
      .csr_rs1_val(rs1_val),
      .csr_uimm(dec.rs1),
      .csr_rdata(csr_rdata),
      .trap_taken(trap_taken),
      .trap_pc(trap_pc_v),
      .trap_cause(trap_cause_v),
      .mret(mret_taken),
      .irq_ext(irq_to_core),
      .fp_fflags_in(fpu_fflags),
      .fp_commit(ir_valid_r && exec_ph && dec.is_fp && (dec.opcode == OP_FP) && !trap_taken),
      .mtvec_o(mtvec),
      .mepc_o(mepc),
      .frm_o(frm_value),
      .mie_global(mie_global),
      .irq_pending(irq_pending)
  );

  trap_ctrl u_trap (
      .clk(clk),
      .rst_n(rst_n),
      .instr_commit(instr_commit),
      .commit_pc(pc_r),
      .commit_pc_plus4(pc_plus4),
      .commit_opcode(dec.opcode),
      .commit_funct3(dec.funct3),
      .commit_branch_taken(branch_taken_r),
      .commit_branch_target(branch_target_r),
      .commit_addr_misaligned(addr_misaligned),
      .illegal_instr(dec_illegal && ir_valid_r && exec_ph),
      .is_mret(is_mret && exec_ph && ir_valid_r),
      .irq_pending(irq_pending),
      .trap_taken(trap_taken),
      .trap_cause(trap_cause_v),
      .trap_pc(trap_pc_v),
      .mret_taken(mret_taken)
  );

endmodule

`endif
