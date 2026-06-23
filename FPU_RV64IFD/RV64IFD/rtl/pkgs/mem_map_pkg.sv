// =============================================================================
// mem_map_pkg.sv — physical address map
//
// Single source of truth for every address constant in the SoC.
// Both RTL and software (linker.ld, start.S) must agree on these values.
//
// Map (spec §2.4.2, §3.0.4, §3.0.8):
//
//   0x0000_0000 .. 0x0000_FFFF   I-MEM   64 KB  instruction ROM  (I-Bus only)
//   0x0001_0000 .. 0x0001_FFFF   D-MEM   64 KB  data RAM         (D-Bus only)
//   0x1000_0000 .. 0x1000_00FF   UART0   256 B  Wishbone MMIO
//   0x1000_0100 .. 0x1000_01FF   GPIO0   256 B  Wishbone MMIO
//   0x1000_0200 .. 0x1000_02FF   QSPI0   256 B  Wishbone MMIO
//   0x1000_0300 .. 0x1000_03FF   IRQ_CTL 256 B  Wishbone MMIO
//   0x1000_0400 .. 0x1000_04FF   CLK_CTL 256 B  Wishbone MMIO
//   0x1000_0500 .. 0x1000_05FF   JTAG    256 B  Wishbone MMIO (debug region)
//
// Note on DMEM addressing:
//   The spec (§3.0.4) states D-MEM is at "0x0001_0000–0x0001_FFFF".
//   The previous placeholder value of 0x8000_0000 was a simulation
//   convenience and is NOT spec-compliant. This file corrects it.
//   Update linker.ld DMEM origin to match.
// =============================================================================

`ifndef MEM_MAP_PKG_H
`define MEM_MAP_PKG_H 

`timescale 1ns / 1ps

package mem_map_pkg;

  import isa_pkg::XLEN;

  typedef logic [XLEN-1:0] addr_t;

  // ===========================================================================
  // Instruction Memory (I-MEM)
  // ===========================================================================
  parameter addr_t IMEM_BASE = 64'h0000_0000_0000_0000;
  parameter addr_t IMEM_SIZE = 64'h0000_0000_0001_0000;  // 64 KB
  parameter addr_t IMEM_MASK = IMEM_SIZE - 1;
  parameter addr_t IMEM_END = IMEM_BASE + IMEM_SIZE - 1;

  // Depth in 32-bit words
  parameter int unsigned IMEM_DEPTH = int'(IMEM_SIZE) / 4;  // 16384 words

  // ===========================================================================
  // Data Memory (D-MEM)
  // Spec §3.0.4: "64 KB block mapped at 0x0001_0000–0x0001_FFFF"
  // ===========================================================================
  parameter addr_t DMEM_BASE = 64'h0000_0000_0001_0000;
  parameter addr_t DMEM_SIZE = 64'h0000_0000_0001_0000;  // 64 KB
  parameter addr_t DMEM_MASK = DMEM_SIZE - 1;
  parameter addr_t DMEM_END = DMEM_BASE + DMEM_SIZE - 1;

  // Depth in 64-bit doublewords
  parameter int unsigned DMEM_DEPTH = int'(DMEM_SIZE) / 8;  // 8192 doublewords

  // Stack top — top of DMEM, grows downward
  parameter addr_t STACK_TOP = DMEM_END + 1;

  // ===========================================================================
  // Wishbone MMIO region (spec §2.5, §3.0.8)
  // All peripherals connected via Wishbone bus
  // ===========================================================================
  parameter addr_t PERIPH_BASE = 64'h0000_0000_1000_0000;
  parameter addr_t PERIPH_SIZE = 64'h0000_0000_0001_0000;  // 64 KB window
  parameter addr_t PERIPH_END = PERIPH_BASE + PERIPH_SIZE - 1;

  // --- UART0 (spec §2.1.2, §2.5) ---
  parameter addr_t UART0_BASE = PERIPH_BASE + 64'h0000;
  parameter addr_t UART0_SIZE = 64'h100;
  parameter addr_t UART0_END = UART0_BASE + UART0_SIZE - 1;

  // --- GPIO0 (spec §2.1.2, §2.5) ---
  parameter addr_t GPIO0_BASE = PERIPH_BASE + 64'h0100;
  parameter addr_t GPIO0_SIZE = 64'h100;
  parameter addr_t GPIO0_END = GPIO0_BASE + GPIO0_SIZE - 1;

  // --- QSPI0 (spec §2.1.2, §2.5) ---
  parameter addr_t QSPI0_BASE = PERIPH_BASE + 64'h0200;
  parameter addr_t QSPI0_SIZE = 64'h100;
  parameter addr_t QSPI0_END = QSPI0_BASE + QSPI0_SIZE - 1;

  // --- Interrupt Controller (spec §2.5, §3.0.5) ---
  parameter addr_t IRQ_CTL_BASE = PERIPH_BASE + 64'h0300;
  parameter addr_t IRQ_CTL_SIZE = 64'h100;
  parameter addr_t IRQ_CTL_END = IRQ_CTL_BASE + IRQ_CTL_SIZE - 1;

  // --- Clock Control Unit / PCG (spec §2.5, §3.0.6) ---
  parameter addr_t CLK_CTL_BASE = PERIPH_BASE + 64'h0400;
  parameter addr_t CLK_CTL_SIZE = 64'h100;
  parameter addr_t CLK_CTL_END = CLK_CTL_BASE + CLK_CTL_SIZE - 1;

  // --- JTAG region (spec §2.5, §4.1.2) ---
  parameter addr_t JTAG_BASE = PERIPH_BASE + 64'h0500;
  parameter addr_t JTAG_SIZE = 64'h100;
  parameter addr_t JTAG_END = JTAG_BASE + JTAG_SIZE - 1;

  // Future slots (pre-allocated)
  // parameter addr_t PWM0_BASE  = PERIPH_BASE + 64'h0600;
  // parameter addr_t TIMER0_BASE = PERIPH_BASE + 64'h0700;

  // ===========================================================================
  // Address decode functions — used in top.sv and sim testbenches
  // ===========================================================================
  function automatic logic in_imem(input addr_t addr);
    return (addr >= IMEM_BASE) && (addr <= IMEM_END);
  endfunction

  function automatic logic in_dmem(input addr_t addr);
    return (addr >= DMEM_BASE) && (addr <= DMEM_END);
  endfunction

  function automatic logic in_periph(input addr_t addr);
    return (addr >= PERIPH_BASE) && (addr <= PERIPH_END);
  endfunction

  function automatic logic in_uart0(input addr_t addr);
    return (addr >= UART0_BASE) && (addr <= UART0_END);
  endfunction

  function automatic logic in_gpio0(input addr_t addr);
    return (addr >= GPIO0_BASE) && (addr <= GPIO0_END);
  endfunction

  function automatic logic in_qspi0(input addr_t addr);
    return (addr >= QSPI0_BASE) && (addr <= QSPI0_END);
  endfunction

  function automatic logic in_irq_ctl(input addr_t addr);
    return (addr >= IRQ_CTL_BASE) && (addr <= IRQ_CTL_END);
  endfunction

  function automatic logic in_clk_ctl(input addr_t addr);
    return (addr >= CLK_CTL_BASE) && (addr <= CLK_CTL_END);
  endfunction

  function automatic logic in_jtag(input addr_t addr);
    return (addr >= JTAG_BASE) && (addr <= JTAG_END);
  endfunction


endpackage

`endif  // MEM_MAP_PKG_H
