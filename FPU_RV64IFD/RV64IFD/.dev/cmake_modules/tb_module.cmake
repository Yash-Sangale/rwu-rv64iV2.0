# =============================================================================
# tb_module.cmake — testbench registration
#
# Provides register_tb() which records:
#   - The testbench source file  (validated to exist at configure time)
#   - The RTL modules it depends on  (validated to be registered)
#   - Optional per-test overrides: TIMEOUT, WAVE, LABEL
#
# All storage uses GLOBAL PROPERTIES — same single-store model as rtl_module.cmake.
#
# Usage (in tb/unit/<name>/CMakeLists.txt):
#
#   register_tb(
#       NAME        tb_alu
#       TB          tb_alu.sv          # relative to CMAKE_CURRENT_SOURCE_DIR
#       RTL_MODULES alu                # must already be registered
#       TIMEOUT     120                # optional, seconds (default: 120)
#       WAVE        ON                 # optional, overrides global WAVE option
#       LABEL       unit               # optional, default: unit
#   )
#
# New argument vs original:
#   LABEL — lets individual testbenches be tagged "unit", "integration", etc.
#            without needing separate finalize_*() calls.
# =============================================================================

function(register_tb)
    cmake_parse_arguments(ARG
        ""                               # boolean flags  (none)
        "NAME;TB;TIMEOUT;WAVE;LABEL"     # single-value args
        "RTL_MODULES"                    # multi-value args
        ${ARGN}
    )

    # --- Validate NAME -------------------------------------------------------
    if(NOT ARG_NAME)
        message(FATAL_ERROR
            "[tb_module] register_tb called without NAME.\n"
            "  Called from: ${CMAKE_CURRENT_LIST_FILE}"
        )
    endif()

    # --- Validate TB argument ------------------------------------------------
    if(NOT ARG_TB)
        message(FATAL_ERROR
            "[tb_module] register_tb(${ARG_NAME}): TB argument missing.\n"
            "  Called from: ${CMAKE_CURRENT_LIST_FILE}"
        )
    endif()

    set(_tb_abs "${CMAKE_CURRENT_SOURCE_DIR}/${ARG_TB}")
    if(NOT EXISTS "${_tb_abs}")
        message(FATAL_ERROR
            "[tb_module] register_tb(${ARG_NAME}): TB file not found:\n"
            "  ${_tb_abs}\n"
            "  Called from: ${CMAKE_CURRENT_LIST_FILE}"
        )
    endif()

    # --- Validate RTL_MODULES ------------------------------------------------
    if(NOT ARG_RTL_MODULES)
        message(FATAL_ERROR
            "[tb_module] register_tb(${ARG_NAME}): RTL_MODULES is empty.\n"
            "  Called from: ${CMAKE_CURRENT_LIST_FILE}"
        )
    endif()

    get_property(_registered GLOBAL PROPERTY RTL_ALL_MODULE_NAMES)
    foreach(_m ${ARG_RTL_MODULES})
        list(FIND _registered "${_m}" _idx)
        if(_idx EQUAL -1)
            message(FATAL_ERROR
                "[tb_module] register_tb(${ARG_NAME}): RTL module '${_m}' not registered.\n"
                "  Registered modules: ${_registered}\n"
                "  Ensure add_subdirectory(rtl/${_m}) appears BEFORE\n"
                "  add_subdirectory(tb/unit/${ARG_NAME}) in root CMakeLists.txt."
            )
        endif()
    endforeach()

    # --- Reject duplicate test names -----------------------------------------
    get_property(_all_tests GLOBAL PROPERTY ALL_TB_NAMES)
    list(FIND _all_tests "${ARG_NAME}" _dup)
    if(NOT _dup EQUAL -1)
        message(FATAL_ERROR
            "[tb_module] register_tb: test '${ARG_NAME}' registered more than once.\n"
            "  Called from: ${CMAKE_CURRENT_LIST_FILE}"
        )
    endif()

    # --- Apply defaults ------------------------------------------------------
    if(NOT ARG_TIMEOUT)
        set(ARG_TIMEOUT 120)
    endif()

    # Per-test WAVE overrides the global WAVE option when explicitly set
    if(NOT DEFINED ARG_WAVE OR ARG_WAVE STREQUAL "")
        set(ARG_WAVE "${WAVE}")   # inherit from root CMakeLists.txt option
    endif()

    # Per-test LABEL (default: unit)
    if(NOT ARG_LABEL)
        set(ARG_LABEL "unit")
    endif()

    # --- Store everything in global properties (one store only) --------------
    set_property(GLOBAL APPEND PROPERTY ALL_TB_NAMES         "${ARG_NAME}")
    set_property(GLOBAL PROPERTY        TB_${ARG_NAME}_FILE    "${_tb_abs}")
    set_property(GLOBAL PROPERTY        TB_${ARG_NAME}_MODULES "${ARG_RTL_MODULES}")
    set_property(GLOBAL PROPERTY        TB_${ARG_NAME}_TIMEOUT "${ARG_TIMEOUT}")
    set_property(GLOBAL PROPERTY        TB_${ARG_NAME}_WAVE    "${ARG_WAVE}")
    set_property(GLOBAL PROPERTY        TB_${ARG_NAME}_LABEL   "${ARG_LABEL}")

    message(STATUS "[tb_module] Registered '${ARG_NAME}'  label=${ARG_LABEL}  RTL: ${ARG_RTL_MODULES}")
endfunction()
