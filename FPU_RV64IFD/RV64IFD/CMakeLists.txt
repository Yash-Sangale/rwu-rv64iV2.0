cmake_minimum_required(VERSION 3.20)

project(riscv64_mcu LANGUAGES NONE)

enable_testing()

# =============================================================================
# Options
# =============================================================================
set(SIM "vivado" CACHE STRING "Simulator backend: vivado | verilator")
set_property(CACHE SIM PROPERTY STRINGS "vivado" "verilator")

option(WAVE              "Capture waveform for every simulation"              OFF)
option(AUTO_PROVISION_RISCV "Download RISC-V GCC toolchain if not on PATH"   OFF)

# =============================================================================
# CMake module path
# =============================================================================
list(APPEND CMAKE_MODULE_PATH "${CMAKE_SOURCE_DIR}/.dev/cmake_modules")

# =============================================================================
# Load modules
# Order matters:
#   toolchain   — detects all tools, sets ACTIVE_SIM and path variables
#   rtl_module  — provides register_rtl_module() / get_rtl_files()
#   tb_module   — provides register_tb()
#   synth_module— provides register_synth_run()
#   targets     — provides finalize_tests()  (must be last)
# =============================================================================

# =============================================================================
# Local RISC-V Toolchain
# =============================================================================

set(
    LOCAL_RISCV_TOOLCHAIN
    "C:/Users/sanga/Documents/GitHub/RISC-V-64/toolcahin/xpack-riscv-none-elf-gcc-15.2.0-1/bin"
    CACHE PATH
    "Local xPack RISC-V toolchain"
)

include(toolchain)
include(rtl_module)
include(tb_module)
include(synth_module)
include(fw_module)
include(targets)

# =============================================================================
# RTL modules Globnal Packages — MUST come before RTL mODULES subdirectories
# =============================================================================

# rtl/pkg/ — SystemVerilog packages included in every compile step
set(RTL_PKG_DIR "${CMAKE_SOURCE_DIR}/rtl/pkgs" CACHE INTERNAL "RTL package include directory")
if(NOT EXISTS "${RTL_PKG_DIR}")
    message(WARNING "[toolchain] rtl/pkg/ not found at ${RTL_PKG_DIR}")
endif()

# =============================================================================
# RTL modules — MUST come before testbench subdirectories
# =============================================================================


add_subdirectory(rtl/core/i_regfile)
add_subdirectory(rtl/core/f_regfile)
add_subdirectory(rtl/core/csr_regfile)
add_subdirectory(rtl/core/prog_counter)
add_subdirectory(rtl/core/ins_decoder)

add_subdirectory(rtl/memory/d_mem)
add_subdirectory(rtl/memory/i_mem)

add_subdirectory(rtl/alu)
add_subdirectory(rtl/fpu)

add_subdirectory(rtl/hazard)

add_subdirectory(rtl/trap)

add_subdirectory(rtl/peripherals/clk_ctrl)
add_subdirectory(rtl/peripherals/gpio)
add_subdirectory(rtl/peripherals/irq_ctrl)
add_subdirectory(rtl/peripherals/uart0)

add_subdirectory(rtl/wishbone_bus)

add_subdirectory(rtl/top_npl)

# =============================================================================
# Firmware modules
# =============================================================================

add_subdirectory(sw/asm/integer_basic)
add_subdirectory(sw/asm/fpu_basic)
# add_subdirectory(sw/asm/genric/integer_basic)
# add_subdirectory(sw/asm/genric/fpu_basic)

# add_subdirectory(sw/asm/alu_sanity)
# add_subdirectory(sw/asm/fpu_sanity)

# =============================================================================
# Testbench modules
# =============================================================================
add_subdirectory(tb/unit/alu)
add_subdirectory(tb/unit/i_regfile)
add_subdirectory(tb/unit/f_regfile)
add_subdirectory(tb/unit/d_mem)
add_subdirectory(tb/unit/i_mem)
add_subdirectory(tb/unit/ins_decoder)
add_subdirectory(tb/unit/fpu)

add_subdirectory(tb/integration/top_npl)
# add_subdirectory(tb/integration/top_npl_genric)
# add_subdirectory(tb/integration/top_npl_sanity)



# =============================================================================
# Synthesis runs (uncomment when a top-level module exists)
# =============================================================================
# register_synth_run(
#     NAME        synth_top
#     TOP         riscv_top
#     PART        xc7a35tcpg236-1
#     RTL_MODULES alu fpu ins_decoder i_regfile f_regfile d_mem i_mem
#     XDC         constraints/top.xdc
# )

# =============================================================================
# Finalize — creates all CTest entries.  Must be LAST.
# =============================================================================
finalize_tests()
