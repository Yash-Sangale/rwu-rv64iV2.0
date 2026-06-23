# =============================================================================
# scripts/verilator/sim_driver.cmake — Verilator simulation driver
#
# Invoked by CTest via:
#   cmake -D<vars> -P scripts/verilator/sim_driver.cmake
#
# Required -D variables (all set by targets.cmake):
#   VERILATOR_EXE   absolute path to verilator binary
#   VERILATOR_ROOT  verilator install root  (for include/verilated.h etc.)
#   TB_FILE         absolute path to testbench .sv
#   RTL_FILES       pipe-separated RTL .sv paths
#   RTL_PKG_DIR     path to rtl/pkg/
#   WORK_DIR        per-test working directory
#   WAVE            ON | OFF  (ON → generate VCD, open GTKWave if available)
#
# Optional:
#   GTKWAVE_EXE     path to gtkwave  (used when WAVE=ON)
#   GTKWAVE_FOUND   TRUE | FALSE
#
# Pipeline:
#   1. verilator --cc --exe --build  → generates and compiles C++ model
#   2. Run the produced simulation binary  → writes *_result.txt
#   3. If WAVE=ON and GTKWave found: open the .vcd in GTKWave
#   4. Evaluate *_result.txt via common/result_check.cmake
#
# Testbench requirements for Verilator:
#   The testbench must be a SystemVerilog module with a C++ DPI harness, OR
#   a pure SystemVerilog testbench compiled with --timing (Verilator 5+).
#   The +RESULT_FILE plusarg is passed as a C string via $value$plusargs or
#   the DPI equivalent.
# =============================================================================

cmake_minimum_required(VERSION 3.20)

# =============================================================================
# Validate required variables
# =============================================================================
foreach(_var VERILATOR_EXE TB_FILE RTL_FILES RTL_PKG_DIR WORK_DIR)
    if(NOT DEFINED ${_var} OR "${${_var}}" STREQUAL "")
        message(FATAL_ERROR "[verilator_driver] Missing required variable: ${_var}")
    endif()
endforeach()

if(NOT EXISTS "${TB_FILE}")
    message(FATAL_ERROR "[verilator_driver] TB_FILE not found: ${TB_FILE}")
endif()
if(NOT EXISTS "${RTL_PKG_DIR}")
    message(FATAL_ERROR "[verilator_driver] RTL_PKG_DIR not found: ${RTL_PKG_DIR}")
endif()

string(REPLACE "|" ";" _rtl_list "${RTL_FILES}")
get_filename_component(_tb_name "${TB_FILE}" NAME_WE)

set(_result_file "${WORK_DIR}/${_tb_name}_result.txt")
set(_obj_dir     "${WORK_DIR}/obj_dir_${_tb_name}")
set(_bin         "${WORK_DIR}/sim_${_tb_name}")
set(_vcd         "${WORK_DIR}/${_tb_name}.vcd")

# =============================================================================
# Initialise log
# =============================================================================
file(WRITE "${WORK_DIR}/sim_full.log" "verilator sim_driver.cmake — ${_tb_name}\n\n")

message("========================================")
message(" [SIM] ${_tb_name}  (Verilator)")
message(" TB : ${TB_FILE}")
message(" RTL: ${_rtl_list}")
message(" VCD: ${WAVE}")
message("========================================")

# =============================================================================
# Step 1 — Verilate + compile  (verilator --cc --exe --build)
# =============================================================================
message("[SIM] 1/2 — Verilate & compile")

set(_v_args
    --cc                          # generate C++ model
    --exe                         # include a main() wrapper
    --build                       # compile immediately after generating
    --sv                          # SystemVerilog input
    --timing                      # enable delay/event scheduling (Verilator 5+)
    -DSIMULATION                  # ifdef guard matching xvlog --define SIMULATION
    "+incdir+${RTL_PKG_DIR}"      # package include path
    -o "${_bin}"
    --Mdir "${_obj_dir}"
    --error-limit 20
)

if(WAVE STREQUAL "ON" OR WAVE STREQUAL "1" OR WAVE STREQUAL "TRUE")
    list(APPEND _v_args --trace)   # emit VCD
endif()

# Append RTL files then TB (order matches xvlog compile order)
list(APPEND _v_args ${_rtl_list} "${TB_FILE}")

execute_process(
    COMMAND "${VERILATOR_EXE}" ${_v_args}
    WORKING_DIRECTORY "${WORK_DIR}"
    OUTPUT_VARIABLE _out
    ERROR_VARIABLE  _err
    RESULT_VARIABLE _rc
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_STRIP_TRAILING_WHITESPACE
)

if(_out)
    message("${_out}")
endif()
if(_err)
    message("${_err}")
endif()
file(APPEND "${WORK_DIR}/sim_full.log" "===== verilator =====\n${_out}\n${_err}\n\n")

if(NOT _rc EQUAL 0)
    message("[SIM] FAILED — Verilator compilation failed (${_rc})")
    message("  Log: ${WORK_DIR}/sim_full.log")
    cmake_language(EXIT 1)
endif()

if(NOT EXISTS "${_bin}")
    message("[SIM] FAILED — simulation binary not produced: ${_bin}")
    cmake_language(EXIT 1)
endif()

# =============================================================================
# Step 2 — Run simulation binary
# =============================================================================
message("[SIM] 2/2 — Running simulation")

set(_run_args "+RESULT_FILE=${_result_file}")
if(WAVE STREQUAL "ON" OR WAVE STREQUAL "1" OR WAVE STREQUAL "TRUE")
    list(APPEND _run_args "+VCD_FILE=${_vcd}")
endif()

execute_process(
    COMMAND "${_bin}" ${_run_args}
    WORKING_DIRECTORY "${WORK_DIR}"
    OUTPUT_VARIABLE _out
    ERROR_VARIABLE  _err
    RESULT_VARIABLE _rc
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_STRIP_TRAILING_WHITESPACE
)

if(_out)
    message("${_out}")
endif()
if(_err)
    message("${_err}")
endif()
file(APPEND "${WORK_DIR}/sim_full.log" "===== simulation =====\n${_out}\n${_err}\n\n")

# Non-zero exit is not immediately fatal — the result file takes precedence.
# A DUT that calls $fatal() may exit non-zero but still write STATUS=FAIL.
if(NOT _rc EQUAL 0)
    message("[SIM] WARNING — simulation binary exited with code ${_rc}")
endif()

# =============================================================================
# Optional: open GTKWave
# =============================================================================
if(WAVE STREQUAL "ON" OR WAVE STREQUAL "1" OR WAVE STREQUAL "TRUE")
    if(GTKWAVE_FOUND AND GTKWAVE_EXE AND EXISTS "${_vcd}")
        message("[SIM] Opening GTKWave: ${_vcd}")
        execute_process(
            COMMAND "${GTKWAVE_EXE}" "${_vcd}"
            RESULT_VARIABLE _gw_rc
        )
        # GTKWave exit code is not meaningful for pass/fail
    elseif(NOT GTKWAVE_FOUND OR NOT GTKWAVE_EXE)
        message("[SIM] INFO — GTKWave not found; VCD written to ${_vcd}")
    elseif(NOT EXISTS "${_vcd}")
        message("[SIM] WARNING — WAVE=ON but no VCD produced at ${_vcd}")
    endif()
endif()

# =============================================================================
# Evaluate result
# =============================================================================
include("${CMAKE_CURRENT_LIST_DIR}/../common/result_check.cmake")
