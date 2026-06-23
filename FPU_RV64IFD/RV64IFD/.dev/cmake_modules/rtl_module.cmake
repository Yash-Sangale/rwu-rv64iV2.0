# =============================================================================
# rtl_module.cmake — RTL module registry
#
# Provides register_rtl_module() and get_rtl_files().
# Storage: EXCLUSIVELY global properties (no CACHE INTERNAL dual-store).
#
# Usage (in rtl/<module>/CMakeLists.txt):
#
#   register_rtl_module(
#       NAME alu
#       FILES
#           ${CMAKE_CURRENT_SOURCE_DIR}/alu_top.sv
#           ${CMAKE_CURRENT_SOURCE_DIR}/alu_shifter.sv
#   )
#
# Bug fixed vs original:
#   message(STATUS "... (${_count} files)") was called BEFORE
#   list(LENGTH ARG_FILES _count) set _count, so it always printed "(files)".
#   Fixed by moving list(LENGTH) before the message.
# =============================================================================

# -----------------------------------------------------------------------------
# register_rtl_module(NAME <name> FILES <file> [<file> ...])
# -----------------------------------------------------------------------------
function(register_rtl_module)
    cmake_parse_arguments(ARG "" "NAME" "FILES" ${ARGN})

    # --- Validate required arguments -----------------------------------------
    if(NOT ARG_NAME)
        message(FATAL_ERROR
            "[rtl_module] register_rtl_module called without NAME.\n"
            "  Called from: ${CMAKE_CURRENT_LIST_FILE}"
        )
    endif()

    if(NOT ARG_FILES)
        message(FATAL_ERROR
            "[rtl_module] register_rtl_module(${ARG_NAME}): FILES is empty.\n"
            "  Called from: ${CMAKE_CURRENT_LIST_FILE}"
        )
    endif()

    # --- Warn on duplicate registration --------------------------------------
    get_property(_existing GLOBAL PROPERTY RTL_MODULE_${ARG_NAME}_FILES)
    if(_existing)
        message(WARNING
            "[rtl_module] Module '${ARG_NAME}' registered more than once.\n"
            "  Previous definition will be overwritten.\n"
            "  Called from: ${CMAKE_CURRENT_LIST_FILE}"
        )
    endif()

    # --- Validate every listed file exists at configure time ----------------
    foreach(_f ${ARG_FILES})
        if(NOT EXISTS "${_f}")
            message(FATAL_ERROR
                "[rtl_module] Module '${ARG_NAME}': file not found:\n"
                "  ${_f}\n"
                "  Called from: ${CMAKE_CURRENT_LIST_FILE}"
            )
        endif()
    endforeach()

    # --- Deduplicate ---------------------------------------------------------
    list(REMOVE_DUPLICATES ARG_FILES)

    # --- Store (single source of truth) --------------------------------------
    set_property(GLOBAL PROPERTY        RTL_MODULE_${ARG_NAME}_FILES "${ARG_FILES}")
    set_property(GLOBAL APPEND PROPERTY RTL_ALL_MODULE_NAMES         "${ARG_NAME}")

    # BUG FIX: list(LENGTH) must come BEFORE the message that uses _count.
    # Original code printed _count before it was set, so it always showed "".
    list(LENGTH ARG_FILES _count)
    message(STATUS "[rtl_module] Registered '${ARG_NAME}'  (${_count} file(s))")

    foreach(_f ${ARG_FILES})
        message(VERBOSE "[rtl_module]   ${_f}")
    endforeach()
endfunction()

# -----------------------------------------------------------------------------
# get_rtl_files(<module_name> <output_variable>)
# Sets <output_variable> in the caller's scope.
# FATAL_ERROR if the module was never registered.
# -----------------------------------------------------------------------------
function(get_rtl_files MODULE_NAME OUT_VAR)
    get_property(_files GLOBAL PROPERTY RTL_MODULE_${MODULE_NAME}_FILES)

    if(NOT _files)
        get_property(_all_names GLOBAL PROPERTY RTL_ALL_MODULE_NAMES)
        list(FIND _all_names "${MODULE_NAME}" _idx)
        if(_idx EQUAL -1)
            message(FATAL_ERROR
                "[rtl_module] get_rtl_files: module '${MODULE_NAME}' was never registered.\n"
                "  Registered modules: ${_all_names}\n"
                "  Check that add_subdirectory(rtl/${MODULE_NAME}) appears BEFORE\n"
                "  add_subdirectory(tb/...) in the root CMakeLists.txt."
            )
        endif()
    endif()

    set(${OUT_VAR} "${_files}" PARENT_SCOPE)
endfunction()
