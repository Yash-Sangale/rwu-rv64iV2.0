# =============================================================================
# result_check.cmake — shared simulation pass/fail evaluation
#
# Included at the end of every sim_driver.cmake (vivado, verilator, ...).
# Callers must set these variables before including this file:
#   _result_file   — absolute path to the *_result.txt written by the testbench
#   _tb_name       — testbench module name (used in log messages only)
#   WORK_DIR       — simulation working directory (used in log messages only)
#
# Contract with testbenches:
#   The testbench must write a file whose path is passed via the plusarg
#   +RESULT_FILE=<path>.  The file must contain exactly one of:
#       STATUS=PASS
#       STATUS=FAIL
#       STATUS=FAIL\nREASON=<short description>
# =============================================================================

if(NOT DEFINED _result_file OR NOT DEFINED _tb_name)
    message(FATAL_ERROR
        "[result_check] _result_file and _tb_name must be set before including this file."
    )
endif()

# --- Check the result file was actually written ------------------------------
if(NOT EXISTS "${_result_file}")
    message("[SIM] FAILED — testbench did not write result file: ${_result_file}")
    message("  This usually means the simulation crashed before $finish.")
    message("  Full log: ${WORK_DIR}/sim_full.log")
    cmake_language(EXIT 1)
endif()

file(READ "${_result_file}" _result)
string(STRIP "${_result}" _result)

# --- Evaluate ----------------------------------------------------------------
if(_result MATCHES "STATUS=PASS")
    message("[SIM] PASSED — ${_tb_name}")
    cmake_language(EXIT 0)

elseif(_result MATCHES "STATUS=FAIL")
    string(REGEX MATCH "REASON=[^\n]*" _reason "${_result}")
    message("[SIM] FAILED — ${_tb_name}")
    if(_reason)
        message("  ${_reason}")
    endif()
    message("  Result : ${_result_file}")
    message("  Log    : ${WORK_DIR}/sim_full.log")
    cmake_language(EXIT 1)
else()
    message("[SIM] FAILED — unexpected content in result file:")
    message("  ${_result}")
    message("  Result : ${_result_file}")
    cmake_language(EXIT 1)
endif()
