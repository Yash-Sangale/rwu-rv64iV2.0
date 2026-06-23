`timescale 1ns/1ps

`ifndef TOP_NPL_SV
`define TOP_NPL_SV

`include "isa_pkg.sv"
`include "types_pkg.sv"
`include "wb_pkg.sv"
`include "mem_map_pkg.sv"

`include "i_mem.sv"
`include "d_mem.sv"
`include "wb_intercon.sv"
`include "uart0.sv"
`include "gpio.sv"
`include "irq_ctl.sv"
`include "clk_ctl.sv"
`include "csr_regfile.sv"
`include "trap_ctrl.sv"
`include "i_regfile.sv"
`include "ins_decoder.sv"

import isa_pkg::*;
import types_pkg::*;
import wb_pkg::*;
import mem_map_pkg::*;

// No-pipeline RV64IM SoC.
//
// FSM: 4-state, one instruction per 3-4 cycles.
//   ST_FETCH0  — drive PC to I-MEM
//   ST_FETCH1  — latch IR from I-MEM output register
//   ST_EXEC    — decode + ALU + D-MEM/WB request initiation
//   ST_EXECLD  — latch load data from D-MEM/WB (loads only)
//
// Harvard architecture:
//   I-Bus: PC → i_mem (direct)
//   D-Bus: ALU result → d_mem (direct for DMEM) | wb_intercon (peripherals)
//
// Interrupt model (from professor's asCPUx.sv):
//   "IRQ is Master, FSM is Slave" — trap is checked at instr_commit
//   boundary (ST_EXEC non-load, or ST_EXECLD), never mid-instruction.
//   mret_pending is set during ST_EXEC and consumed during the next ST_FETCH0.
module top_npl #(
    parameter string IMEM_INIT_FILE = "",
    parameter string DMEM_INIT_FILE = "",
    parameter int    CLK_FREQ_HZ    = 80_000_000,
    parameter int    BAUD_RATE      = 115_200
) (
    input  logic        clk,
    input  logic        rst_n,

    output logic        uart_tx,
    input  logic        uart_rx,

    inout  tri  [31:0]  gpio_io,   // tristate — direction controlled by GPIO.DIR

    output logic        cs_o       // GPIO chip-select pulse for testbench monitoring
);

    // =========================================================================
    // FSM
    // =========================================================================
    typedef enum logic [1:0] {
        ST_FETCH0,
        ST_FETCH1,
        ST_EXEC,
        ST_EXECLD
    } state_t;

    state_t state_r, state_next;

    // opcode of current IR — needed for load detection before full decode
    logic [6:0] opcode_ir;
    assign opcode_ir = ir_r[6:0];

    logic is_load_exec;
    assign is_load_exec = (opcode_ir == OP_LOAD) && (state_r == ST_EXEC);

    always_comb begin
        state_next = state_r;
        unique case (state_r)
            ST_FETCH0: state_next = ST_FETCH1;
            ST_FETCH1: state_next = ST_EXEC;
            ST_EXEC:   state_next = is_load_exec ? ST_EXECLD : ST_FETCH0;
            ST_EXECLD: state_next = ST_FETCH0;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) state_r <= ST_FETCH0;
        else        state_r <= state_next;

    logic fetch0_ph, fetch1_ph, exec_ph, execld_ph;
    assign fetch0_ph = (state_r == ST_FETCH0);
    assign fetch1_ph = (state_r == ST_FETCH1);
    assign exec_ph   = (state_r == ST_EXEC);
    assign execld_ph = (state_r == ST_EXECLD);

    // instr_commit: point at which architectural state is updated
    // matches professor's: (exec_phase && !load_pending) || execld_phase
    logic instr_commit;
    assign instr_commit = (exec_ph && !is_load_exec) || execld_ph;

    // =========================================================================
    // CSR signals (forward declarations — connected to csr_regfile below)
    // =========================================================================
    logic [XLEN-1:0] mtvec, mepc;
    logic            mie_global, irq_pending;
    logic            trap_taken, mret_taken;
    logic [XLEN-1:0] trap_cause_v, trap_pc_v;

    // mret_pending: set at end of EXEC (like professor's mret_pending_s),
    // consumed at next FETCH0 to redirect PC to mepc
    logic mret_pending_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            mret_pending_r <= 1'b0;
        else if (exec_ph && mret_taken)   // @Note: mret_taken is combinational from trap_ctrl
            mret_pending_r <= 1'b1;
        else if (fetch0_ph)
            mret_pending_r <= 1'b0;
    end

    // =========================================================================
    // Program Counter
    // =========================================================================
    logic [XLEN-1:0] pc_r;
    logic [XLEN-1:0] pc_plus4;
    logic [XLEN-1:0] branch_target;
    logic            branch_taken;

    assign pc_plus4 = pc_r + 64'd4;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            pc_r <= '0;
        else if (fetch0_ph) begin
            if (trap_taken)
                pc_r <= {mtvec[XLEN-1:2], 2'b00};
            else if (mret_pending_r)
                pc_r <= mepc;
            else if (branch_taken)
                pc_r <= branch_target;
            else
                pc_r <= pc_plus4;
        end
    end

    // =========================================================================
    // Instruction Memory (I-Bus, Harvard)
    // =========================================================================
    logic [ILEN-1:0] imem_rdata;
    logic            imem_valid;

    i_mem #(
        .INIT_FILE (IMEM_INIT_FILE),
        .PARITY_EN (1)
    ) u_imem (
        .clk        (clk),
        .rst_n      (rst_n),
        .cs         (fetch0_ph || fetch1_ph),
        .addr       (pc_r),
        .rdata      (imem_rdata),
        .valid      (imem_valid),
        .parity_err (),
        .jtag_we    (1'b0),
        .jtag_addr  ('0),
        .jtag_wdata ('0)
    );

    // =========================================================================
    // Instruction Register
    // =========================================================================
    logic [ILEN-1:0] ir_r;
    logic            ir_valid_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ir_r       <= 32'h0000_0013;  // NOP
            ir_valid_r <= 1'b0;
        end else if (fetch1_ph) begin
            if (!mret_pending_r) begin
                ir_r       <= imem_rdata;
                ir_valid_r <= imem_valid;
            end else begin
                ir_r       <= 32'h0000_0013;
                ir_valid_r <= 1'b0;
            end
        end else if (trap_taken || (exec_ph && mret_taken)) begin
            ir_r       <= 32'h0000_0013;
            ir_valid_r <= 1'b0;
        end
    end

    // =========================================================================
    // Decoder
    // =========================================================================
    decoded_instr_t dec;
    logic           dec_illegal;

    ins_decoder u_dec (
        .instr   (ir_r),
        .dec     (dec),
        .illegal (dec_illegal)
    );

    // MRET detection (directly from IR bits, not via decoder)
    logic is_mret;
    assign is_mret = (ir_r[6:0] == OP_SYSTEM) &&
                     (ir_r[14:12] == 3'b000)     &&
                     (ir_r[31:20] == 12'h302);

    // =========================================================================
    // Integer Register File
    // =========================================================================
    logic [XLEN-1:0] rs1_val, rs2_val;
    logic            rf_we;
    logic [4:0]      rf_waddr;
    logic [XLEN-1:0] rf_wdata;

    i_regfile u_rf (
        .clk     (clk),
        .rst_n   (rst_n),
        .rs1_addr(dec.rs1),
        .rs1_data(rs1_val),
        .rs2_addr(dec.rs2),
        .rs2_data(rs2_val),
        .rd_addr (rf_waddr),
        .rd_data (rf_wdata),
        .rd_we   (rf_we)
    );

    // =========================================================================
    // ALU (inline — reuses instruction_t encoding)
    // =========================================================================
    logic [XLEN-1:0] alu_a, alu_b, alu_result;

    always_comb begin
        // SRC_A: rs1, PC (AUIPC), or zero (LUI)
        alu_a = rs1_val;
        if (dec.opcode == OP_AUIPC) alu_a = pc_r;
        if (dec.opcode == OP_LUI)   alu_a = '0;

        // SRC_B: immediate or rs2
        alu_b = dec.alu_src ? dec.imm : rs2_val;
    end

    always_comb begin
        unique case (dec.instruction)
            INST_ADD:  alu_result = alu_a + alu_b;
            INST_SUB:  alu_result = alu_a - alu_b;
            INST_AND:  alu_result = alu_a & alu_b;
            INST_OR:   alu_result = alu_a | alu_b;
            INST_XOR:  alu_result = alu_a ^ alu_b;
            INST_SLL:  alu_result = alu_a << alu_b[5:0];
            INST_SRL:  alu_result = alu_a >> alu_b[5:0];
            INST_SRA:  alu_result = $signed(alu_a) >>> alu_b[5:0];
            INST_SLT:  alu_result = {63'b0, $signed(alu_a) < $signed(alu_b)};
            INST_SLTU: alu_result = {63'b0, alu_a < alu_b};
            INST_LUI:  alu_result = alu_b;
            INST_ADDW: alu_result = {{32{alu_a[31] ^ alu_b[31]}}, alu_a[31:0] + alu_b[31:0]};
            INST_SUBW: alu_result = {{32{alu_a[31] ^ alu_b[31]}}, alu_a[31:0] - alu_b[31:0]};
            INST_SLLW: alu_result = {{32{1'b0}}, alu_a[31:0] << alu_b[4:0]};
            INST_SRLW: alu_result = {{32{1'b0}}, alu_a[31:0] >> alu_b[4:0]};
            INST_SRAW: alu_result = {{32{alu_a[31]}}, $signed(alu_a[31:0]) >>> alu_b[4:0]};
            // @Todo: INST_MUL..INST_REMU — hook up mul_div.sv when ready
            default:   alu_result = alu_a + alu_b;
        endcase
    end

    // =========================================================================
    // Branch evaluation
    // =========================================================================
    always_comb begin
        branch_taken  = 1'b0;
        branch_target = pc_r + dec.imm;  // PC-relative default

        if (exec_ph && ir_valid_r) begin
            if (dec.jal) begin
                branch_taken = 1'b1;
            end else if (dec.jalr) begin
                branch_taken  = 1'b1;
                branch_target = (rs1_val + dec.imm) & ~64'h1;
            end else if (dec.branch) begin
                unique case (dec.funct3)
                    3'b000: branch_taken = (rs1_val == rs2_val);
                    3'b001: branch_taken = (rs1_val != rs2_val);
                    3'b100: branch_taken = $signed(rs1_val) < $signed(rs2_val);
                    3'b101: branch_taken = $signed(rs1_val) >= $signed(rs2_val);
                    3'b110: branch_taken = rs1_val < rs2_val;
                    3'b111: branch_taken = rs1_val >= rs2_val;
                    default: branch_taken = 1'b0;
                endcase
            end
        end
    end

    // =========================================================================
    // Misalignment detection (combinational, used by trap_ctrl)
    // =========================================================================
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
            if ((dec.branch && branch_taken) || dec.jal || dec.jalr)
                if (branch_target[1:0] != 2'b00)
                    addr_misaligned = 1'b1;
        end
    end

    // =========================================================================
    // D-Bus routing: DMEM direct or Wishbone peripheral
    // =========================================================================
    logic is_mem_op;
    logic is_dmem_access, is_periph_access;

    assign is_mem_op       = ir_valid_r && exec_ph && (dec.mem_read || dec.mem_write);
    assign is_dmem_access  = is_mem_op && in_dmem(alu_result);
    assign is_periph_access = is_mem_op && in_periph(alu_result);

    // Byte select
    function automatic logic [7:0] funct3_sel(
        input logic [2:0] f3,
        input logic [2:0] lsb
    );
        unique case (f3)
            3'b000, 3'b100: return 8'b0000_0001 << lsb;
            3'b001, 3'b101: return 8'b0000_0011 << {lsb[2:1], 1'b0};
            3'b010, 3'b110: return 8'b0000_1111 << {lsb[2],   2'b00};
            3'b011:         return 8'b1111_1111;
            default:        return 8'b0;
        endcase
    endfunction

    logic [7:0] dmem_sel_s;
    assign dmem_sel_s = funct3_sel(dec.funct3, alu_result[2:0]);

    // DMEM direct port
    logic            dmem_cs_r;
    logic [XLEN-1:0] dmem_rdata_s;
    logic            dmem_ack_s;

    assign dmem_cs_r = is_dmem_access;

    d_mem #(
        .INIT_FILE (DMEM_INIT_FILE),
        .FWD_EN    (1),
        .PARITY_EN (1)
    ) u_dmem (
        .clk       (clk),
        .rst_n     (rst_n),
        .cs        (dmem_cs_r),
        .we        (dec.mem_write),
        .addr      (alu_result),
        .sel       (dmem_sel_s),
        .wdata     (rs2_val),
        .rdata     (dmem_rdata_s),
        .ack       (dmem_ack_s),
        .parity_err(),
        .dbg_addr  ('0),
        .dbg_rdata ()
    );

    // Wishbone port for peripherals
    wb_req_t  dbus_req;
    wb_resp_t dbus_resp;

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

    // Raw read data (before extension)
    logic [XLEN-1:0] raw_rdata;
    assign raw_rdata = is_dmem_access ? dmem_rdata_s : dbus_resp.dat;

    // Load sign/zero extension
    logic [XLEN-1:0] load_data;
    always_comb begin
        logic [7:0]  bl;
        logic [15:0] hl;
        logic [31:0] wl;
        bl = raw_rdata >> ({alu_result[2:0], 3'b0});
        hl = raw_rdata >> ({alu_result[2:1], 4'b0});
        wl = raw_rdata >> ({alu_result[2],   5'b0});
        unique case (dec.funct3)
            3'b000: load_data = {{56{bl[7]}},  bl};
            3'b001: load_data = {{48{hl[15]}}, hl};
            3'b010: load_data = {{32{wl[31]}}, wl};
            3'b011: load_data = raw_rdata;
            3'b100: load_data = {56'b0, bl};
            3'b101: load_data = {48'b0, hl};
            3'b110: load_data = {32'b0, wl};
            default: load_data = raw_rdata;
        endcase
    end

    // =========================================================================
    // CSR instruction detection
    // =========================================================================
    logic is_csr;
    assign is_csr = ir_valid_r && exec_ph &&
                    (dec.opcode == OP_SYSTEM) && (dec.funct3 != 3'b000);

    logic [XLEN-1:0] csr_rdata;

    // =========================================================================
    // Result mux → register file writeback
    // =========================================================================
    logic [XLEN-1:0] result_v;

    always_comb begin
        unique case (dec.opcode)
            OP_LOAD:          result_v = load_data;
            OP_JAL, OP_JALR:  result_v = pc_plus4;
            OP_SYSTEM:        result_v = csr_rdata;
            default:          result_v = alu_result;
        endcase
    end

    // Write on EXEC (non-load) or EXECLD (load complete); suppress on trap
    assign rf_we    = ir_valid_r && dec.reg_write && !trap_taken
                      && ((exec_ph && !is_load_exec) || execld_ph)
                      && (dec.rd != 5'd0);
    assign rf_waddr = dec.rd;
    assign rf_wdata = (execld_ph) ? load_data : result_v;

    // =========================================================================
    // Peripheral stall (for execld on peripheral reads)
    // @Note: NPL does not stall mid-FSM — peripheral ACK is expected within
    //   ST_EXEC. If a peripheral needs >1 cycle, extend with a wait loop here.
    //   For now all peripherals have combinational ACK (wb_resp.ack same cycle).
    // =========================================================================

    // =========================================================================
    // Wishbone Interconnect
    // =========================================================================
    wb_req_t  uart_req, gpio_req, qspi_req, irq_req, clk_req, jtag_req;
    wb_resp_t uart_resp, gpio_resp, qspi_resp, irq_resp, clk_resp, jtag_resp;

    wb_intercon u_intercon (
        .clk       (clk),
        .rst_n     (rst_n),
        .m_req     (dbus_req),
        .m_resp    (dbus_resp),
        .uart_req  (uart_req),   .uart_resp (uart_resp),
        .gpio_req  (gpio_req),   .gpio_resp (gpio_resp),
        .qspi0_req (qspi_req),   .qspi0_resp(qspi_resp),
        .irq_req   (irq_req),    .irq_resp  (irq_resp),
        .clk_req   (clk_req),    .clk_resp  (clk_resp),
        .jtag_req  (jtag_req),   .jtag_resp (jtag_resp)
    );

    // QSPI and JTAG stubs — @Todo implement when needed
    assign qspi_resp = WB_RESP_IDLE;
    assign jtag_resp = WB_RESP_IDLE;

    // =========================================================================
    // UART0
    // =========================================================================
    uart0 #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ),
        .BAUD_RATE   (BAUD_RATE)
    ) u_uart (
        .clk    (clk),
        .rst_n  (rst_n),
        .wb_req (uart_req),
        .wb_resp(uart_resp),
        .tx     (uart_tx),
        .rx     (uart_rx),
        .irq    ()
    );

    // =========================================================================
    // GPIO0
    // =========================================================================
    logic [31:0] gpio_in_s, gpio_out_s, gpio_oe_s;
    logic irq_gpio;

    // Tristate driver
    genvar gi;
    generate
        for (gi = 0; gi < 32; gi++) begin : gpio_pad
            assign gpio_io[gi] = gpio_oe_s[gi] ? gpio_out_s[gi] : 1'bz;
            assign gpio_in_s[gi] = gpio_io[gi];
        end
    endgenerate

    gpio u_gpio (
        .clk    (clk),
        .rst_n  (rst_n),
        .wb_req (gpio_req),
        .wb_resp(gpio_resp),
        .gpio_in (gpio_in_s),
        .gpio_out(gpio_out_s),
        .gpio_oe (gpio_oe_s),
        .irq    (irq_gpio)
    );

    // cs_o: pulses when GPIO register is accessed — used by testbench monitor
    // matches professor's pattern (cs_o connected to GPIO chip-select)
    assign cs_o = gpio_req.cyc && gpio_req.stb;

    // =========================================================================
    // IRQ Controller
    // =========================================================================
    logic irq_uart_s;
    logic [7:0] irq_src_s;
    logic irq_to_core;

    assign irq_src_s = {6'b0, irq_gpio, irq_uart_s};

    irq_ctl #(.N_IRQ(8)) u_irqctl (
        .clk    (clk),
        .rst_n  (rst_n),
        .wb_req (irq_req),
        .wb_resp(irq_resp),
        .irq_src(irq_src_s),
        .irq_out(irq_to_core),
        .irq_vec()
    );

    // =========================================================================
    // Clock Control
    // =========================================================================
    clk_ctl u_clkctl (
        .clk     (clk),
        .rst_n   (rst_n),
        .wb_req  (clk_req),
        .wb_resp (clk_resp),
        .clk_core(),
        .clk_bus (),
        .clk_qspi()
    );

    // =========================================================================
    // CSR Register File
    // =========================================================================
    csr_regfile u_csr (
        .clk         (clk),
        .rst_n       (rst_n),
        .csr_en      (is_csr),
        .csr_addr    (ir_r[31:20]),
        .csr_funct3  (dec.funct3),
        .csr_rs1_val (rs1_val),
        .csr_uimm    (dec.rs1),
        .csr_rdata   (csr_rdata),
        .trap_taken  (trap_taken),
        .trap_pc     (trap_pc_v),
        .trap_cause  (trap_cause_v),
        .mret        (mret_taken),
        .irq_ext     (irq_to_core),
        .mtvec_o     (mtvec),
        .mepc_o      (mepc),
        .mie_global  (mie_global),
        .irq_pending (irq_pending)
    );

    // =========================================================================
    // Trap Controller
    // =========================================================================
    trap_ctrl u_trap (
        .clk                  (clk),
        .rst_n                (rst_n),
        .instr_commit         (instr_commit),
        .commit_pc            (pc_r),
        .commit_pc_plus4      (pc_plus4),
        .commit_opcode        (dec.opcode),
        .commit_funct3        (dec.funct3),
        .commit_branch_taken  (branch_taken),
        .commit_branch_target (branch_target),
        .commit_addr_misaligned(addr_misaligned),
        .illegal_instr        (dec_illegal && ir_valid_r && exec_ph),
        .is_mret              (is_mret && exec_ph && ir_valid_r),
        .irq_pending          (irq_pending),
        .trap_taken           (trap_taken),
        .trap_cause           (trap_cause_v),
        .trap_pc              (trap_pc_v),
        .mret_taken           (mret_taken)
    );

endmodule

`endif
