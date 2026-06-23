# =============================================================================
# synth_module.cmake — synthesis run registration
#
# Provides register_synth_run() which records a Vivado synthesis +
# implementation + bitstream job.  Jobs are created as CTest entries
# labelled "synth" by finalize_tests() in targets.cmake.
#
# Usage (in root CMakeLists.txt or a dedicated synth/ subdirectory):
#
#   register_synth_run(
#       NAME        synth_top             # unique name for ctest -R
#       TOP         riscv_top             # top-level module name
#       PART        xc7a35tcpg236-1       # Xilinx device part string
#       RTL_MODULES alu fpu ins_decoder i_regfile f_regfile d_mem i_mem
#       XDC         constraints/top.xdc   # relative to CMAKE_SOURCE_DIR
#       TIMEOUT     3600                  # optional, seconds (default: 3600)
#   )
#
# Run synthesis:
#   ctest --preset synth           (all synth runs)
#   ctest -L synth -R synth_top    (specific run)
# =============================================================================

function(register_synth_run)
    cmake_parse_arguments(ARG
        ""
        "NAME;TOP;PART;XDC;TIMEOUT"
        "RTL_MODULES"
        ${ARGN}
    )

    # --- Validate required arguments -----------------------------------------
    foreach(_req NAME TOP PART)
        if(NOT ARG_${_req})
            message(FATAL_ERROR
                "[synth] register_synth_run: missing required argument ${_req}.\n"
                "  Called from: ${CMAKE_CURRENT_LIST_FILE}"
            )
        endif()
    endforeach()

    if(NOT ARG_RTL_MODULES)
        message(FATAL_ERROR
            "[synth] register_synth_run(${ARG_NAME}): RTL_MODULES is empty.\n"
            "  Called from: ${CMAKE_CURRENT_LIST_FILE}"
        )
    endif()

    # --- Validate RTL modules are registered ---------------------------------
    get_property(_registered GLOBAL PROPERTY RTL_ALL_MODULE_NAMES)
    foreach(_m ${ARG_RTL_MODULES})
        list(FIND _registered "${_m}" _idx)
        if(_idx EQUAL -1)
            message(FATAL_ERROR
                "[synth] register_synth_run(${ARG_NAME}): RTL module '${_m}' not registered.\n"
                "  Registered modules: ${_registered}"
            )
        endif()
    endforeach()

    # --- Validate XDC if provided --------------------------------------------
    if(ARG_XDC)
        set(_xdc_abs "${CMAKE_SOURCE_DIR}/${ARG_XDC}")
        if(NOT EXISTS "${_xdc_abs}")
            message(FATAL_ERROR
                "[synth] register_synth_run(${ARG_NAME}): XDC file not found:\n"
                "  ${_xdc_abs}"
            )
        endif()
    else()
        set(_xdc_abs "")
    endif()

    # --- Reject duplicates ---------------------------------------------------
    get_property(_all GLOBAL PROPERTY ALL_SYNTH_NAMES)
    list(FIND _all "${ARG_NAME}" _dup)
    if(NOT _dup EQUAL -1)
        message(FATAL_ERROR
            "[synth] register_synth_run: '${ARG_NAME}' registered more than once."
        )
    endif()

    # --- Apply defaults -------------------------------------------------------
    if(NOT ARG_TIMEOUT)
        set(ARG_TIMEOUT 3600)
    endif()

    # --- Store ---------------------------------------------------------------
    set_property(GLOBAL APPEND PROPERTY ALL_SYNTH_NAMES              "${ARG_NAME}")
    set_property(GLOBAL PROPERTY        SYNTH_${ARG_NAME}_TOP        "${ARG_TOP}")
    set_property(GLOBAL PROPERTY        SYNTH_${ARG_NAME}_PART       "${ARG_PART}")
    set_property(GLOBAL PROPERTY        SYNTH_${ARG_NAME}_MODULES    "${ARG_RTL_MODULES}")
    set_property(GLOBAL PROPERTY        SYNTH_${ARG_NAME}_XDC        "${_xdc_abs}")
    set_property(GLOBAL PROPERTY        SYNTH_${ARG_NAME}_TIMEOUT    "${ARG_TIMEOUT}")

    message(STATUS "[synth] Registered '${ARG_NAME}'  top=${ARG_TOP}  part=${ARG_PART}")
endfunction()
