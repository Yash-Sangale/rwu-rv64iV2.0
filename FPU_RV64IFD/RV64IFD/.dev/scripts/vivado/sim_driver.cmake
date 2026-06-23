# =============================================================================
# scripts/vivado/sim_driver.cmake — Vivado xsim simulation driver
#
# Invoked by CTest via:
#   cmake -D<vars> -P scripts/vivado/sim_driver.cmake
#
# Required -D variables (all set by targets.cmake):
#   XVLOG_EXE       absolute path to xvlog / xvlog.bat
#   XELAB_EXE       absolute path to xelab / xelab.bat
#   XSIM_EXE        absolute path to xsim  / xsim.bat
#   TB_FILE         absolute path to testbench .sv
#   RTL_FILES       pipe-separated RTL .sv paths  (| not ;)
#   RTL_PKG_DIR     path to rtl/pkg/  (include directory)
#   WORK_DIR        per-test working directory (all artefacts land here)
#   WAVE            ON | OFF
#
# Windows / Linux behaviour:
#   On Windows, Vivado ships .bat wrappers (xvlog.bat, xelab.bat, xsim.bat).
#   CMake's execute_process() cannot launch .bat files directly — they must be
#   called via "cmd /c <path-to.bat> <args>".  No settings64.bat is needed;
#   the .bat wrappers are self-contained and do not require the environment
#   script for batch-mode simulation.
#   On Linux the binaries are native ELF executables and are called directly.
# =============================================================================

cmake_minimum_required(VERSION 3.20)

# =============================================================================
# Platform-aware command builder
#
# On Linux: calls the binary directly — arguments are separate list items,
#   CMake passes them to execve() without any shell, so no quoting needed.
#
# On Windows: Vivado tools are .bat wrappers that require "cmd /c".
#   When cmd /c receives a command, it parses it as a single shell string —
#   so arguments containing spaces or colons (e.g. C:/path/to/file) must be
#   individually double-quoted.  We build a single quoted command string and
#   pass it as one token after cmd /c.
#
# Usage:  vivado_cmd(_out_list  "${XVLOG_EXE}"  arg1 arg2 ...)
# =============================================================================
function(vivado_cmd OUT_VAR EXE)
    set(${OUT_VAR} "${EXE}" ${ARGN} PARENT_SCOPE)
endfunction()

# =============================================================================
# Helper: run one pipeline step, capture output, abort on failure
# =============================================================================
macro(run_step STEP_NAME)
    if(DEFINED XILINX_VIVADO AND NOT XILINX_VIVADO STREQUAL "")
        set(_env ENVIRONMENT "XILINX_VIVADO=${XILINX_VIVADO}")
    else()
        set(_env "")
    endif()

    execute_process(
        COMMAND ${ARGN}
        WORKING_DIRECTORY "${WORK_DIR}"
        ${_env}
        OUTPUT_VARIABLE _step_out
        ERROR_VARIABLE _step_err
        RESULT_VARIABLE _step_rc
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_STRIP_TRAILING_WHITESPACE
    )

    if(_step_out)
        message("${STEP_NAME} stdout:\n${_step_out}")
    endif()
    if(_step_err)
        message("${STEP_NAME} stderr:\n${_step_err}")
    endif()

    file(APPEND "${WORK_DIR}/sim_full.log"
        "===== ${STEP_NAME} =====\n${_step_out}\n${_step_err}\n\n"
    )

    if(NOT _step_rc EQUAL 0)
        message("[SIM] FAILED — ${STEP_NAME} exited with code ${_step_rc}")
        message("  Log: ${WORK_DIR}/sim_full.log")
        cmake_language(EXIT 1)
    endif()
endmacro()

# cmake_language(EXIT) requires CMake 3.25; graceful fallback for older versions
if(CMAKE_VERSION VERSION_LESS "3.25")
    macro(cmake_language_exit CODE)
        if(NOT CODE EQUAL 0)
            message(FATAL_ERROR "[SIM] Aborting — see log above")
        endif()
    endmacro()
endif()

# =============================================================================
# Validate required variables
# =============================================================================
foreach(_var XVLOG_EXE XELAB_EXE XSIM_EXE TB_FILE RTL_FILES RTL_PKG_DIR WORK_DIR)
    if(NOT DEFINED ${_var} OR "${${_var}}" STREQUAL "")
        message(FATAL_ERROR "[vivado_driver] Missing required variable: ${_var}")
    endif()
endforeach()

if(NOT EXISTS "${TB_FILE}")
    message(FATAL_ERROR "[vivado_driver] TB_FILE not found: ${TB_FILE}")
endif()

if(NOT EXISTS "${RTL_PKG_DIR}")
    message(FATAL_ERROR "[vivado_driver] RTL_PKG_DIR not found: ${RTL_PKG_DIR}")
endif()

# =============================================================================
# Reconstruct file lists
# =============================================================================
string(REPLACE "|" ";" _rtl_list "${RTL_FILES}")

foreach(_f ${_rtl_list})
    if(NOT EXISTS "${_f}")
        message("[SIM] FAILED — RTL file not found: ${_f}")
        cmake_language(EXIT 1)
    endif()
endforeach()

# Collect pkg/ package files — compiled first so every module can use them
file(GLOB _pkg_files "${RTL_PKG_DIR}/*.sv")
if(NOT _pkg_files)
    message(WARNING "[vivado_driver] No .sv files in RTL_PKG_DIR: ${RTL_PKG_DIR}")
endif()

# Compile order: pkg → RTL → TB
set(_all_sv ${_pkg_files} ${_rtl_list} "${TB_FILE}")
list(REMOVE_DUPLICATES _all_sv)

get_filename_component(_tb_name "${TB_FILE}" NAME_WE)

# =============================================================================
# Initialise log
# =============================================================================
file(WRITE "${WORK_DIR}/sim_full.log" "vivado sim_driver.cmake — ${_tb_name}\n\n")

message("========================================")
message(" [SIM] ${_tb_name}  (Vivado/xsim)")
message(" TB : ${TB_FILE}")
message(" RTL: ${_rtl_list}")
message(" PKG: ${_pkg_files}")
message(" WDB: ${WAVE}")
message("========================================")

# =============================================================================
# Step 1 — Compile  (xvlog)
# =============================================================================
message("[SIM] 1/3 — Compile (xvlog)")

vivado_cmd(_xvlog_cmd "${XVLOG_EXE}"
    -sv
    --incr
    -i "${RTL_PKG_DIR}"
    -work work
    --define SIMULATION
    ${_all_sv}
)
run_step("xvlog" ${_xvlog_cmd})

# =============================================================================
# Step 2 — Elaborate  (xelab)
# =============================================================================
message("[SIM] 2/3 — Elaborate (xelab)")

set(_elab_args
    "${_tb_name}"
    -s "snapshot_${_tb_name}"
    -i "${RTL_PKG_DIR}"
    --debug all
    --nolog
)
if(WAVE STREQUAL "ON" OR WAVE STREQUAL "1" OR WAVE STREQUAL "TRUE")
    list(APPEND _elab_args --debug wave)
endif()

vivado_cmd(_xelab_cmd "${XELAB_EXE}" ${_elab_args})
run_step("xelab" ${_xelab_cmd})

# =============================================================================
# Step 3 — Simulate  (xsim)
# =============================================================================
message("[SIM] 3/3 — Simulate (xsim)")

set(_result_file "${WORK_DIR}/${_tb_name}_result.txt")
# Normalise to forward slashes — cmd /c and xsim both accept them, and it
# avoids backslashes being mis-parsed inside vivado_cmd on Windows.
file(TO_CMAKE_PATH "${_result_file}" _result_file)

# CMAKE_CURRENT_LIST_DIR always points to this script's own directory
# (.dev/scripts/vivado/) so wave.tcl is always found correctly.
set(_wave_tcl "${CMAKE_CURRENT_LIST_DIR}/wave.tcl")
file(TO_CMAKE_PATH "${_wave_tcl}" _wave_tcl)
file(RELATIVE_PATH _rel_result "${WORK_DIR}" "${_result_file}")
if(DEFINED XILINX_VIVADO AND NOT XILINX_VIVADO STREQUAL "")
    set(_env ENVIRONMENT "XILINX_VIVADO=${XILINX_VIVADO}")
else()
    set(_env "")
endif()
if(WAVE STREQUAL "ON" OR WAVE STREQUAL "1" OR WAVE STREQUAL "TRUE")

    # --- GUI / waveform mode -------------------------------------------------
    message("[SIM] Launching xsim GUI — close the window when done.")

    vivado_cmd(_xsim_gui_cmd "${XSIM_EXE}"
        "snapshot_${_tb_name}"
        --gui
        --tclbatch "${_wave_tcl}"
        "--testplusarg=RESULT_FILE"
        --wdb "${WORK_DIR}/${_tb_name}.wdb"
    )

    execute_process(
        COMMAND ${_xsim_gui_cmd}
        WORKING_DIRECTORY "${WORK_DIR}"
        ${_env}
        RESULT_VARIABLE _rc
        OUTPUT_VARIABLE _out
        ERROR_VARIABLE _err
    )
    if(_out)
        message("${_out}")
    endif()
    if(_err)
        message("${_err}")
    endif()
    file(APPEND "${WORK_DIR}/sim_full.log" "===== xsim (GUI) =====\n${_out}\n${_err}\n\n")

    if(NOT _rc EQUAL 0)
        message("[SIM] FAILED — xsim GUI exited with code ${_rc}")
        cmake_language(EXIT 1)
    endif()

    if(NOT EXISTS "${_result_file}")
        message("[SIM] INFO — GUI closed before result file was written (no pass/fail recorded).")
        cmake_language(EXIT 0)
    endif()
else()

    # --- Batch mode ----------------------------------------------------------
    # On Windows, cmd /c splits "--testplusarg RESULT_FILE=C:/..." at the colon.
    # Workaround: write a one-line TCL batch script that calls "run all; quit"
    # and pass the result file path via xsim's TCL environment instead of
    # --testplusarg.  The result path is written to a known sidecar file that
    # the testbench locates via a fixed relative plusarg with no drive letter.

    # Convert to a relative path from WORK_DIR — no drive letter, no colon.
    file(RELATIVE_PATH _rel_result "${WORK_DIR}" "${_result_file}")

    vivado_cmd(_xsim_cmd "${XSIM_EXE}"
        "snapshot_${_tb_name}"
        --runall
        --nolog
        "--testplusarg=RESULT_FILE"
    )

    message("XSIM CMD = ${_xsim_cmd}")
    run_step("xsim" ${_xsim_cmd})

    get_filename_component(_tb_dir "${TB_FILE}" DIRECTORY)

    # typo fix
    set(_out_dir "${_tb_dir}/result")
    file(MAKE_DIRECTORY "${_out_dir}")

    # variable expansion fix
    if(EXISTS "${_result_file}")
        
        file(COPY "${_result_file}" DESTINATION "${_out_dir}")
    else()
        message(NOTICE "Result file not found: ${_result_file}")
    endif()

    if(EXISTS "${WORK_DIR}/sim_full.log")
        file(COPY "${WORK_DIR}/sim_full.log" DESTINATION "${_out_dir}")
    else()
        message(NOTICE "Log file not found: ${WORK_DIR}/sim_full.log")
    endif()

endif()

# =============================================================================
# Evaluate result
# =============================================================================
include("${CMAKE_CURRENT_LIST_DIR}/../common/result_check.cmake")
