# =============================================================================
# check_tools.cmake — tool presence summary
#
# Included at the end of toolchain.cmake.
# Prints a colour-coded table so a developer on a fresh clone sees immediately
# what is installed and what must be installed before they can work.
#
# Uses only STATUS messages so the output is always visible (not filtered by
# --log-level).  The [OK] / [!!] prefixes make it easy to grep.
# =============================================================================

# Helper: one row of the table
function(_tool_row LABEL FOUND_VAR INSTALL_HINT)
    if(${FOUND_VAR})
        message(STATUS "  [OK]  ${LABEL}")
    else()
        message(STATUS "  [!!]  ${LABEL}  —  NOT FOUND")
        message(STATUS "        Install:  ${INSTALL_HINT}")
    endif()
endfunction()

message(STATUS "")
message(STATUS "╔══════════════════════════════════════════════════════════════╗")
message(STATUS "║              Tool Status (riscv64_mcu build)                ║")
message(STATUS "╠══════════════════════════════════════════════════════════════╣")
message(STATUS "║  Simulators                                                  ║")
_tool_row("Vivado / xsim  (SIM=vivado)"
          VIVADO_FOUND
          "Add <Vivado>/bin to PATH  or  -DVIVADO_EXE=<path>")
_tool_row("Verilator      (SIM=verilator)"
          VERILATOR_FOUND
          "sudo apt install verilator   |   brew install verilator")
message(STATUS "║  Waveform viewers                                            ║")
_tool_row("GTKWave        (Verilator waves)"
          GTKWAVE_FOUND
          "sudo apt install gtkwave     |   brew install gtkwave")
message(STATUS "║  Firmware                                                    ║")
_tool_row("RISC-V GCC     (firmware cross-compiler)"
          RISCV_TOOLCHAIN_FOUND
          "-DAUTO_PROVISION_RISCV=ON   or   see docs/install_riscv_gcc.md")
message(STATUS "║  Infrastructure                                              ║")
_tool_row("Git"
          GIT_FOUND
          "https://git-scm.com")
_tool_row("Python 3"
          Python3_FOUND
          "https://python.org  (3.9+)")
message(STATUS "╚══════════════════════════════════════════════════════════════╝")
message(STATUS "  Active simulator: ${ACTIVE_SIM}")
message(STATUS "")
