// =============================================================================
// top_npl.sv — RWU64IMAD No-Pipeline Top
//
// Architecture: sequential, FSM-driven. 4-state cycle per instruction:
//   FETCH0 → FETCH1 → EXEC → EXECLD (load only)
//
// Strategy ported from professor's asCPUx.sv:
//   • "Interrupt is Master, Pipeline is Slave"
//   • trap taken at instruction-commit boundary (instr_commit)
//   • PC advances only on FETCH0 (registered at commit boundary)
//   • IR latched on FETCH1 (with NOP injection on trap/MRET)
//
// Additions over professor's baseline:
//   • Active-low reset (rst_n) throughout
//   • FPU path: fpu_top + f_regfile for RV64FD
//   • Our modular csr_regfile + trap_ctrl instead of inline CSR logic
//   • Full Wishbone peripheral bus (uart0, gpio, irq_ctrl, clk_ctrl)
//   • d_mem / i_mem as Harvard memories (not external bus)
//   • ALU: alu_top with mul/div stub (RV64M)
//   • Byte-enable (sel) generation from funct3 for loads/stores
//
// Reset polarity: all modules use rst_n (active-low).
// =============================================================================

`timescale 1ns / 1ps

`ifndef TOP_NPL_SV
`define TOP_NPL_SV 

`include "isa_pkg.sv"
`include "types_pkg.sv"
`include "mem_map_pkg.sv"
`include "wb_pkg.sv"

import isa_pkg::*;
import types_pkg::*;
import mem_map_pkg::*;
import wb_pkg::*;

module top_npl #(
    parameter string IMEM_INIT = "",
    parameter string DMEM_INIT = ""
) (
    input logic clk,
    input logic rst_n,

    // GPIO
    input  logic [31:0] gpio_in,
    output logic [31:0] gpio_out,
    output logic [31:0] gpio_oe,

    // UART
    output logic uart_tx,
    input  logic uart_rx
);


  // FSM — 4 states (professor's model)

  typedef enum logic [1:0] {
    FETCH0_ST,  // present PC to I-MEM; advance PC
    FETCH1_ST,  // latch instruction from I-MEM
    EXEC_ST,    // execute; write-back; detect load
    EXECLD_ST   // wait one extra cycle for load data
  } state_t;

  state_t state_r, state_next;

  // Phase strobes (combinational from state)
  logic fetch0_ph, fetch1_ph, exec_ph, execld_ph;
  assign fetch0_ph = (state_r == FETCH0_ST);
  assign fetch1_ph = (state_r == FETCH1_ST);
  assign exec_ph   = (state_r == EXEC_ST);
  assign execld_ph = (state_r == EXECLD_ST);

  // FSM next-state
  logic load_pending;  // forward declaration — assigned below
  
  always_comb begin
    state_next = state_r;
    case (state_r)
      FETCH0_ST: state_next = FETCH1_ST;
      FETCH1_ST: state_next = EXEC_ST;
      EXEC_ST:   state_next = load_pending ? EXECLD_ST : FETCH0_ST;
      EXECLD_ST: state_next = FETCH0_ST;
      default:   state_next = FETCH0_ST;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) state_r <= FETCH0_ST;
    else state_r <= state_next;
  end

  // Instruction commits at EXEC or EXECLD (load completes)
  logic instr_commit;
  assign instr_commit = (exec_ph && !load_pending) || execld_ph;


  // Program Counter
  logic [XLEN-1:0] pc_r;
  logic [XLEN-1:0] pc_plus4;
  logic [XLEN-1:0] branch_target;
  logic            branch_taken;

  // Trap / MRET redirect signals (from trap_ctrl + csr_regfile)
  logic            trap_taken;
  logic [XLEN-1:0] mtvec;
  logic [XLEN-1:0] mepc;
  logic            mret_taken;

  assign pc_plus4 = pc_r + 64'd4;

  // PC updates on FETCH0 only (professor's model)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) pc_r <= '0;
    else if (fetch0_ph) begin
      if (trap_taken) pc_r <= {mtvec[63:2], 2'b00};
      else if (mret_taken) pc_r <= mepc;
      else if (branch_taken) pc_r <= branch_target;
      else pc_r <= pc_plus4;
    end
  end


  // Instruction Register (IR)
  logic [ILEN-1:0] ir_r;
  logic            ir_valid_r;
  logic            mret_pending_r;  // MRET detected in EXEC — suppress next fetch

  // MRET decode from fetched word (used in FETCH1 to suppress IR latch)
  logic [ILEN-1:0] imem_rdata;
  logic            imem_valid;
  logic            is_mret_fetched;
  assign is_mret_fetched = (imem_rdata[6:0]   == 7'b111_0011) &&
                           (imem_rdata[14:12]  == 3'b000)      &&
                           (imem_rdata[31:20]  == 12'h302);

  // MRET pending flag: set in EXEC when MRET was in the fetch stream
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) mret_pending_r <= 1'b0;
    else begin
      if (exec_ph && is_mret_fetched) mret_pending_r <= 1'b1;
      else if (fetch0_ph) mret_pending_r <= 1'b0;
    end
  end

  localparam logic [ILEN-1:0] NOP = 32'h0000_0013;  // ADDI x0, x0, 0

  logic is_mret;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ir_r       <= NOP;
      ir_valid_r <= 1'b0;
    end else begin
      if (fetch1_ph) begin
        if (!mret_pending_r) begin
          ir_r       <= imem_rdata;
          ir_valid_r <= imem_valid;
        end else begin
          ir_r       <= NOP;  // NOP while MRET redirect in progress
          ir_valid_r <= 1'b0;
        end
      end else if (trap_taken) begin
        ir_r       <= NOP;  // flush after trap
        ir_valid_r <= 1'b0;
      end else if (is_mret && exec_ph) begin
        ir_r       <= NOP;  // flush after MRET commit
        ir_valid_r <= 1'b0;
      end
    end
  end


  // Instruction Decode
  decoded_instr_t dec;
  logic           illegal_instr;

  ins_decoder u_dec (
      .instr  (ir_r),
      .dec    (dec),
      .illegal(illegal_instr)
  );

  // Convenience aliases
  logic [6:0] opcode;
  assign opcode = ir_r[6:0];

  // MRET detection from committed IR
  assign is_mret = (opcode == 7'b111_0011) && (ir_r[14:12] == 3'b000) && (ir_r[31:20] == 12'h302);

  // Load detection for EXECLD stall
  // assign load_pending = (opcode == OP_LOAD) && exec_ph;  // OP_LOAD
  assign load_pending = ((opcode == OP_LOAD) || ((opcode == OP_LOAD_FP)) ) && exec_ph;  // OP_LOAD & OP_FP_LOAD


  // Integer Register File
  logic [XLEN-1:0] rs1_val, rs2_val;
  logic [XLEN-1:0] wb_data;  // final write-back data (assigned below)
  logic            int_we;

  i_regfile #(
      .ASYNC_READ(1)
  ) u_irf (
      .clk     (clk),
      .rst_n   (rst_n),
      .rs1_addr(dec.rs1),
      .rs1_data(rs1_val),
      .rs2_addr(dec.rs2),
      .rs2_data(rs2_val),
      .rd_addr (dec.rd),
      .rd_data (wb_data),
      .rd_we   (int_we)
  );


  // FP Register File
  logic [FLEN-1:0] fp_rs1_val, fp_rs2_val;
  logic [FLEN-1:0] fp_wb_data;
  logic            fp_we;

  f_regfile #(
      .ASYNC_READ(1)
  ) u_frf (
      .clk     (clk),
      .rst_n   (rst_n),
      .rs1_addr(dec.rs1),
      .rs1_data(fp_rs1_val),
      .rs2_addr(dec.rs2),
      .rs2_data(fp_rs2_val),
      .rd_addr (dec.rd),
      .rd_data (fp_wb_data),
      .rd_we   (fp_we)
  );


  // ALU Operand Muxes
  logic [XLEN-1:0] alu_a, alu_b;

  // Operand A: rs1 or PC (AUIPC / JAL)
  always_comb begin
    if (dec.jal || (dec.opcode == OP_AUIPC)) alu_a = pc_r;
    else alu_a = rs1_val;
  end

  // Operand B: rs2 or immediate
  assign alu_b = dec.alu_src ? dec.imm : rs2_val;


  // ALU
  logic [XLEN-1:0] alu_result;
  logic alu_zero, alu_neg, alu_ov, alu_carry;
  logic flag_eq, flag_lt_s, flag_lt_u;

  alu_top u_alu (
      .inst            (dec.instruction),
      .operand_a       (alu_a),
      .operand_b       (alu_b),
      .result          (alu_result),
      .zero            (alu_zero),
      .negative        (alu_neg),
      .overflow        (alu_ov),
      .carry           (alu_carry),
      .flag_eq         (flag_eq),
      .flag_lt_s       (flag_lt_s),
      .flag_lt_u       (flag_lt_u),
      .clk             (clk),
      .rst_n           (rst_n),
      .muldiv_valid_in (1'b0),
      .muldiv_ready    (),
      .muldiv_valid_out()
  );


  // Branch evaluation
  always_comb begin
    branch_taken  = 1'b0;
    branch_target = alu_result;  // default: ALU computed target (ADD imm)

    if (dec.jal) begin
      branch_taken  = 1'b1;
      branch_target = pc_r + dec.imm;
    end else if (dec.jalr) begin
      branch_taken  = 1'b1;
      branch_target = (rs1_val + dec.imm) & ~64'h1;  // clear bit 0 per spec
    end else if (dec.branch) begin
      branch_target = pc_r + dec.imm;
      case (ir_r[14:12])  // funct3
        3'b000:  branch_taken = flag_eq;  // BEQ
        3'b001:  branch_taken = !flag_eq;  // BNE
        3'b100:  branch_taken = flag_lt_s;  // BLT
        3'b101:  branch_taken = !flag_lt_s;  // BGE
        3'b110:  branch_taken = flag_lt_u;  // BLTU
        3'b111:  branch_taken = !flag_lt_u;  // BGEU
        default: branch_taken = 1'b0;
      endcase
    end
  end


  // FPU
  logic [FLEN-1:0] fpu_result;
  logic            fpu_to_int;
  logic [     4:0] fpu_fflags;
  logic [     2:0] frm;  // from CSR

  // Resolve fp_rm==3'b111 → CSR.frm
  logic [     2:0] fp_rm_eff;
  assign fp_rm_eff = (dec.fp_rm == 3'b111) ? frm : dec.fp_rm;

  fpu_top u_fpu (
      .clk          (clk),
      .rst_n        (rst_n),
      .inst         (dec.instruction),
      .fp_funct5    (dec.fp_funct5),
      .fp_rm        (fp_rm_eff),
      .fp_cvt_toint (dec.fp_cvt_toint),
      .fp_cvt_word  (dec.fp_cvt_word),
      .fp_cvt_signed(dec.fp_cvt_signed),
      .fp_fmt       (dec.fp_fmt),
      .fp_sgn_op    (dec.fp_sgn_op),
      .fp_min_sel   (dec.fp_min_sel),
      .operand_a    (fp_rs1_val),
      .operand_b    (fp_rs2_val),
      .int_operand  (rs1_val),
      .result       (fpu_result),
      .to_int       (fpu_to_int),
      .fflags       (fpu_fflags),
      .div_valid_in (exec_ph && dec.is_fp),
      .div_ready    (),
      .div_valid_out()
  );


  // I-MEM (Harvard instruction bus)
  i_mem #(
      .INIT_FILE(IMEM_INIT),
      .PARITY_EN(0)
  ) u_imem (
      .clk       (clk),
      .rst_n     (rst_n),
      .cs        (fetch0_ph),   // address valid on FETCH0
      .addr      (pc_r),
      .rdata     (imem_rdata),  // data arrives on FETCH1
      .valid     (imem_valid),
      .parity_err(),
      .jtag_we   (1'b0),
      .jtag_addr ('0),
      .jtag_wdata('0)
  );


  // D-MEM (Harvard data bus)
  // Byte-enable from funct3
  logic [XLEN/8-1:0] dmem_sel;
  always_comb begin
    case (ir_r[14:12])
      3'b000, 3'b100: dmem_sel = 8'b0000_0001;  // LB/SB/LBU
      3'b001, 3'b101: dmem_sel = 8'b0000_0011;  // LH/SH/LHU
      3'b010:         dmem_sel = 8'b0000_1111;  // LW/SW
      3'b011:         dmem_sel = 8'b1111_1111;  // LD/SD
      default:        dmem_sel = 8'b1111_1111;
    endcase
  end

  logic [XLEN-1:0] dmem_rdata;
  logic            dmem_ack;
  logic            dmem_cs;

  // D-MEM active during EXEC (store) or EXEC+EXECLD (load)
  assign dmem_cs = exec_ph && ir_valid_r && (dec.mem_read || dec.mem_write) && in_dmem(alu_result);

  // FP store: data comes from FP regfile
  logic [XLEN-1:0] dmem_wdata;
  assign dmem_wdata = dec.fp_store ? fp_rs2_val : rs2_val;

  d_mem #(
      .INIT_FILE(DMEM_INIT),
      .FWD_EN(1),
      .PARITY_EN(0)
  ) u_dmem (
      .clk       (clk),
      .rst_n     (rst_n),
      .cs        (dmem_cs),
      .we        (dec.mem_write && exec_ph),
      .addr      (alu_result),
      .sel       (dmem_sel),
      .wdata     (dmem_wdata),
      .rdata     (dmem_rdata),
      .ack       (dmem_ack),
      .parity_err(),
      .dbg_addr  ('0),
      .dbg_rdata ()
  );


  // Wishbone Peripheral Bus
  wb_req_t wb_req;
  wb_resp_t wb_resp;

  // Drive WB request during EXEC for peripheral-mapped addresses
  logic is_periph_addr;
  assign is_periph_addr = (alu_result >= UART0_BASE) && exec_ph && ir_valid_r &&
                          (dec.mem_read || dec.mem_write);

  always_comb begin
    wb_req = WB_REQ_IDLE;
    if (is_periph_addr) begin
      wb_req.cyc = 1'b1;
      wb_req.stb = 1'b1;
      wb_req.we  = dec.mem_write;
      wb_req.adr = alu_result;
      wb_req.dat = dmem_wdata;
      wb_req.sel = dmem_sel;
    end
  end

  wb_req_t uart_req, gpio_req_s, qspi0_req, irq_req, clk_req, jtag_req;
  wb_resp_t uart_resp, gpio_resp, qspi0_resp, irq_resp, clk_resp, jtag_resp;

  assign qspi0_resp = WB_RESP_IDLE;
  assign jtag_resp  = WB_RESP_IDLE;

  wb_intercon u_wb (
      .clk       (clk),
      .rst_n     (rst_n),
      .m_req     (wb_req),
      .m_resp    (wb_resp),
      .uart_req  (uart_req),
      .uart_resp (uart_resp),
      .gpio_req  (gpio_req_s),
      .gpio_resp (gpio_resp),
      .qspi0_req (qspi0_req),
      .qspi0_resp(qspi0_resp),
      .irq_req   (irq_req),
      .irq_resp  (irq_resp),
      .clk_req   (clk_req),
      .clk_resp  (clk_resp),
      .jtag_req  (jtag_req),
      .jtag_resp (jtag_resp)
  );

  // --- UART0 ---
  logic uart_irq;
  uart0 u_uart (
      .clk    (clk),
      .rst_n  (rst_n),
      .wb_req (uart_req),
      .wb_resp(uart_resp),
      .tx     (uart_tx),
      .rx     (uart_rx),
      .irq    (uart_irq)
  );

  // --- GPIO0 ---
  logic gpio_irq;
  gpio u_gpio (
      .clk     (clk),
      .rst_n   (rst_n),
      .wb_req  (gpio_req_s),
      .wb_resp (gpio_resp),
      .gpio_in (gpio_in),
      .gpio_out(gpio_out),
      .gpio_oe (gpio_oe),
      .irq     (gpio_irq)
  );

  // --- IRQ Controller ---
  logic        irq_out;
  logic [63:0] irq_vec;
  irq_ctrl u_irqc (
      .clk    (clk),
      .rst_n  (rst_n),
      .wb_req (irq_req),
      .wb_resp(irq_resp),
      .irq_src({7'b0, gpio_irq}),
      .irq_out(irq_out),
      .irq_vec(irq_vec)
  );

  // --- Clock Control ---
  logic clk_core, clk_bus, clk_qspi;  // unused in npl; available for future
  clk_ctrl u_clkc (
      .clk     (clk),
      .rst_n   (rst_n),
      .wb_req  (clk_req),
      .wb_resp (clk_resp),
      .clk_core(clk_core),
      .clk_bus (clk_bus),
      .clk_qspi(clk_qspi)
  );


  // Load data mux (D-MEM or peripheral bus)

  logic [XLEN-1:0] load_rdata_raw;
  assign load_rdata_raw = is_periph_addr ? wb_resp.dat : dmem_rdata;

  // Sign-extend / zero-extend loaded value from funct3
  logic [XLEN-1:0] load_rdata;
  always_comb begin
    case (ir_r[14:12])
      3'b000:  load_rdata = {{56{load_rdata_raw[7]}}, load_rdata_raw[7:0]};  // LB
      3'b001:  load_rdata = {{48{load_rdata_raw[15]}}, load_rdata_raw[15:0]};  // LH
      3'b010:  load_rdata = {{32{load_rdata_raw[31]}}, load_rdata_raw[31:0]};  // LW
      3'b011:  load_rdata = load_rdata_raw;  // LD
      3'b100:  load_rdata = {56'b0, load_rdata_raw[7:0]};  // LBU
      3'b101:  load_rdata = {48'b0, load_rdata_raw[15:0]};  // LHU
      3'b110:  load_rdata = {32'b0, load_rdata_raw[31:0]};  // LWU
      default: load_rdata = load_rdata_raw;
    endcase
  end

  // CSR <-> Trap signals
  logic [XLEN-1:0] trap_cause;
  logic [XLEN-1:0] trap_pc;


  // CSR Register File

  logic [XLEN-1:0] csr_rdata;
  logic            csr_en;
  logic            irq_pending;
  logic            mie_global;
  logic            fp_commit;
  logic [     4:0] fp_fflags_wb;

  assign csr_en       = exec_ph && ir_valid_r && (opcode == OP_SYSTEM) && (ir_r[14:12] != 3'b000);
  assign fp_commit    = instr_commit && dec.is_fp;
  assign fp_fflags_wb = fpu_fflags;

  csr_regfile u_csr (
      .clk         (clk),
      .rst_n       (rst_n),
      .csr_en      (csr_en),
      .csr_addr    (ir_r[31:20]),
      .csr_funct3  (ir_r[14:12]),
      .csr_rs1_val (rs1_val),
      .csr_uimm    (ir_r[19:15]),
      .csr_rdata   (csr_rdata),
      .trap_taken  (trap_taken),
      .trap_pc     (trap_pc),
      .trap_cause  (trap_cause),
      .mret        (mret_taken),
      .irq_ext     (irq_out),
      .fp_fflags_in(fp_fflags_wb),
      .fp_commit   (fp_commit),
      .mtvec_o     (mtvec),
      .mepc_o      (mepc),
      .mie_global  (mie_global),
      .irq_pending (irq_pending),
      .frm_o       (frm)
  );


  // Trap Controller

  // logic [XLEN-1:0] trap_cause, trap_pc;
  logic addr_misaligned;

  // Address misalignment for loads/stores — check effective address vs width
  always_comb begin
    addr_misaligned = 1'b0;
    case (ir_r[14:12])
      3'b001, 3'b101: addr_misaligned = (alu_result[0] != 1'b0);  // LH/SH
      3'b010:         addr_misaligned = (alu_result[1:0] != 2'b00);  // LW/SW
      3'b011:         addr_misaligned = (alu_result[2:0] != 3'b000);  // LD/SD
      default:        addr_misaligned = 1'b0;
    endcase
  end

  trap_ctrl u_trap (
      .clk                   (clk),
      .rst_n                 (rst_n),
      .instr_commit          (instr_commit && ir_valid_r),
      .commit_pc             (pc_r),
      .commit_pc_plus4       (pc_plus4),
      .commit_opcode         (opcode),
      .commit_funct3         (ir_r[14:12]),
      .commit_branch_taken   (branch_taken),
      .commit_branch_target  (branch_target),
      .commit_addr_misaligned(addr_misaligned),
      .illegal_instr         (illegal_instr && ir_valid_r),
      .is_mret               (is_mret),
      .irq_pending           (irq_pending),
      .trap_taken            (trap_taken),
      .trap_cause            (trap_cause),
      .trap_pc               (trap_pc),
      .mret_taken            (mret_taken)
  );


  // Write-back Mux & Register File Write Enable

  // Result for integer regfile
  always_comb begin
    if (dec.mem_read && !dec.fp_load) wb_data = load_rdata;  // I-type load
    else if (dec.jal || dec.jalr) wb_data = pc_plus4;  // link address
    else if (csr_en) wb_data = csr_rdata;  // CSR read
    else if (dec.is_fp && fpu_to_int)
      wb_data = fpu_result[XLEN-1:0];  // FPU → int (FCMP, FCVT, FCLASS, FMV.X)
    else wb_data = alu_result;  // normal ALU
  end

  // FP regfile write data
  always_comb begin
    if (dec.fp_load) fp_wb_data = load_rdata;  // FLD: memory → FP rf
    else fp_wb_data = fpu_result;  // FPU result → FP rf
  end

  // Integer write enable: commit, not a trap, not a pure FP-to-FP op
  // assign int_we = instr_commit && ir_valid_r && dec.reg_write &&
  //                 !trap_taken &&
  //                 !(dec.is_fp && !fpu_to_int && !dec.fp_load);

  // Integer regfile gets written by: all non-FP OR FP ops that produce int result
  assign int_we = instr_commit && ir_valid_r && !trap_taken && dec.reg_write &&
               (!dec.is_fp || (dec.is_fp && fpu_to_int));

  // fpu_ctrl hits default branch for INST_FLD → res_sel = FPU_SEL_PASS
  // to_int = cmp_en || (cvt_en && fp_cvt_toint) || class_en || mv_to_int
  //        = 0      ||  0                        ||  0        ||  0
  //  

  // FP write enable: commit, not a trap, FP load or FP op that stays in fp rf
  // assign fp_we  = instr_commit && ir_valid_r && dec.reg_write &&
  //                 !trap_taken &&
  //                 dec.is_fp && !fpu_to_int;

  // FP regfile gets written by: FLD result (from memory) OR FP op that stays in fp rf
  assign fp_we = instr_commit && ir_valid_r && !trap_taken && dec.reg_write &&
               (dec.fp_load || (dec.is_fp && !dec.fp_load && !fpu_to_int));



endmodule

`endif  // TOP_NPL_SV
