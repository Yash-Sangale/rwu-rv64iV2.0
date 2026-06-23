# =============================================================================
# firmware_module.cmake — firmware registration
#
# Provides:
#
#   register_firmware(
#       NAME     hello
#       SOURCES  start.S
#       LINKER   linker.ld
#       ARCH     rv64ifd_zicsr
#       ABI      lp64d
#   )
#
# Stores firmware metadata in GLOBAL PROPERTIES.
# Build targets are created later by targets.cmake.
# =============================================================================

function(register_firmware)

    cmake_parse_arguments(ARG
        ""
        "NAME;LINKER;ARCH;ABI"
        "SOURCES"
        ${ARGN}
    )

    # -------------------------------------------------------------------------
    # Validate NAME
    # -------------------------------------------------------------------------
    if(NOT ARG_NAME)
        message(FATAL_ERROR
            "[firmware_module] register_firmware called without NAME.\n"
            "  Called from: ${CMAKE_CURRENT_LIST_FILE}"
        )
    endif()

    # -------------------------------------------------------------------------
    # Validate SOURCES
    # -------------------------------------------------------------------------
    if(NOT ARG_SOURCES)
        message(FATAL_ERROR
            "[firmware_module] register_firmware(${ARG_NAME}): SOURCES is empty.\n"
            "  Called from: ${CMAKE_CURRENT_LIST_FILE}"
        )
    endif()

    foreach(_src ${ARG_SOURCES})
        if(NOT EXISTS "${_src}")
            message(FATAL_ERROR
                "[firmware_module] Firmware '${ARG_NAME}': source not found:\n"
                "  ${_src}\n"
                "  Called from: ${CMAKE_CURRENT_LIST_FILE}"
            )
        endif()
    endforeach()

    # -------------------------------------------------------------------------
    # Validate LINKER
    # -------------------------------------------------------------------------
    if(NOT ARG_LINKER)
        message(FATAL_ERROR
            "[firmware_module] register_firmware(${ARG_NAME}): LINKER missing.\n"
            "  Called from: ${CMAKE_CURRENT_LIST_FILE}"
        )
    endif()

    if(NOT EXISTS "${ARG_LINKER}")
        message(FATAL_ERROR
            "[firmware_module] Firmware '${ARG_NAME}': linker script not found:\n"
            "  ${ARG_LINKER}"
        )
    endif()

    # -------------------------------------------------------------------------
    # Defaults
    # -------------------------------------------------------------------------
    if(NOT ARG_ARCH)
        set(ARG_ARCH "rv64ifd_zicsr")
    endif()

    if(NOT ARG_ABI)
        set(ARG_ABI "lp64d")
    endif()

    # -------------------------------------------------------------------------
    # Duplicate registration check
    # -------------------------------------------------------------------------
    get_property(_existing GLOBAL PROPERTY FW_${ARG_NAME}_SOURCES)

    if(_existing)
        message(FATAL_ERROR
            "[firmware_module] Firmware '${ARG_NAME}' already registered."
        )
    endif()

    # -------------------------------------------------------------------------
    # Store metadata
    # -------------------------------------------------------------------------
    set_property(GLOBAL APPEND PROPERTY ALL_FIRMWARE_NAMES "${ARG_NAME}")

    set_property(GLOBAL PROPERTY FW_${ARG_NAME}_SOURCES "${ARG_SOURCES}")
    set_property(GLOBAL PROPERTY FW_${ARG_NAME}_LINKER "${ARG_LINKER}")
    set_property(GLOBAL PROPERTY FW_${ARG_NAME}_ARCH "${ARG_ARCH}")
    set_property(GLOBAL PROPERTY FW_${ARG_NAME}_ABI "${ARG_ABI}")

    set_property(
        GLOBAL PROPERTY
        FW_${ARG_NAME}_DIR
        "${CMAKE_CURRENT_SOURCE_DIR}"
    )

    list(LENGTH ARG_SOURCES _count)

    message(STATUS
        "[firmware_module] Registered '${ARG_NAME}' "
        "(${_count} source(s)) "
        "arch=${ARG_ARCH} abi=${ARG_ABI}"
    )

endfunction()

# =============================================================================
# get_firmware_property(<name> <property> <outvar>)
# =============================================================================

function(get_firmware_property FW_NAME PROP OUT_VAR)

    string(TOUPPER "${PROP}" _prop)

    get_property(
        _value
        GLOBAL
        PROPERTY FW_${FW_NAME}_${_prop}
    )

    if(NOT _value)
        get_property(_all GLOBAL PROPERTY ALL_FIRMWARE_NAMES)

        list(FIND _all "${FW_NAME}" _idx)

        if(_idx EQUAL -1)
            message(FATAL_ERROR
                "[firmware_module] Firmware '${FW_NAME}' not registered.\n"
                "Registered firmware: ${_all}"
            )
        endif()
    endif()

    set(${OUT_VAR} "${_value}" PARENT_SCOPE)

endfunction()

# =============================================================================
# get_all_firmware(<outvar>)
# =============================================================================

function(get_all_firmware OUT_VAR)

    get_property(
        _all
        GLOBAL
        PROPERTY ALL_FIRMWARE_NAMES
    )

    set(${OUT_VAR} "${_all}" PARENT_SCOPE)

endfunction()
