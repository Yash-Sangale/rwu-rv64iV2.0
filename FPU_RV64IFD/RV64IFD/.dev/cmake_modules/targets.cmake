# =============================================================================
# targets.cmake — CTest target creation
#
# Provides finalize_tests() — call ONCE at the end of root CMakeLists.txt.
#
# What it does:
#   1. Iterates every registered testbench (ALL_TB_NAMES).
#   2. Assembles the RTL file list from the module registry.
#   3. Dispatches to the correct simulator driver via cmake -P.
#   4. Iterates every registered synthesis run (ALL_SYNTH_NAMES).
#   5. Creates CTest entries labelled "synth".
#
# Bugs fixed vs original:
#   - message("Finalizing ${_count} tests") was called BEFORE
#     list(LENGTH) set _count.  The count was always empty.
#     Fixed by moving list(LENGTH) before the first message that uses it.
#
# New features vs original:
#   - Per-test LABEL read from TB_${name}_LABEL (set by tb_module.cmake).
#   - Backend dispatcher:  vivado → scripts/vivado/sim_driver.cmake
#                          verilator → scripts/verilator/sim_driver.cmake
#   - Synthesis loop that creates "synth"-labelled CTest entries.
# =============================================================================

function(finalize_tests)

    # =========================================================================
    # Part 1 — Simulation testbenches
    # =========================================================================
    get_property(_all_tests GLOBAL PROPERTY ALL_TB_NAMES)

    if(NOT _all_tests)
        message(WARNING "[targets] finalize_tests: no testbenches registered.")
    else()
        # BUG FIX: list(LENGTH) must precede the message that prints _count.
        list(LENGTH _all_tests _count)
        message(STATUS "[targets] Registering ${_count} simulation test(s)...")

        foreach(_test ${_all_tests})

            # --- Retrieve per-test metadata ----------------------------------
            get_property(_tb_file GLOBAL PROPERTY TB_${_test}_FILE)
            get_property(_modules GLOBAL PROPERTY TB_${_test}_MODULES)
            get_property(_timeout GLOBAL PROPERTY TB_${_test}_TIMEOUT)
            get_property(_wave GLOBAL PROPERTY TB_${_test}_WAVE)
            get_property(_label GLOBAL PROPERTY TB_${_test}_LABEL)

            if(NOT _label)
                set(_label "unit") # safe default
            endif()

            # --- Assemble RTL file list --------------------------------------
            set(_rtl_files "")
            foreach(_m ${_modules})
                get_rtl_files(${_m} _mod_files)
                list(APPEND _rtl_files ${_mod_files})
            endforeach()
            list(REMOVE_DUPLICATES _rtl_files)

            # Use | as list separator — avoids cmake semicolon-escaping issues
            # on both Windows and Linux when passing via -DVAR=value.
            string(REPLACE ";" "|" _rtl_str "${_rtl_files}")

            # --- Per-test working directory ----------------------------------
            set(_work_dir "${SIM_OUT_DIR}/${_test}")
            file(MAKE_DIRECTORY "${_work_dir}")

            # --- Backend dispatcher ------------------------------------------
            if(ACTIVE_SIM STREQUAL "vivado")

                add_test(
                    NAME ${_test}
                    COMMAND ${CMAKE_COMMAND}
                    -DXVLOG_EXE=${XVLOG_EXE}
                    -DXELAB_EXE=${XELAB_EXE}
                    -DXSIM_EXE=${XSIM_EXE}
                    -DTB_FILE=${_tb_file}
                    -DRTL_FILES=${_rtl_str}
                    -DRTL_PKG_DIR=${RTL_PKG_DIR}
                    -DWORK_DIR=${_work_dir}
                    -DWAVE=${_wave}
                    -P "${DEV_SCRIPTS_DIR}/vivado/sim_driver.cmake"
                    -DXILINX_VIVADO=${XILINX_VIVADO}
                    WORKING_DIRECTORY "${_work_dir}"
                )

            elseif(ACTIVE_SIM STREQUAL "verilator")

                add_test(
                    NAME ${_test}
                    COMMAND ${CMAKE_COMMAND}
                    -DVERILATOR_EXE=${VERILATOR_EXE}
                    -DVERILATOR_ROOT=${VERILATOR_ROOT}
                    -DGTKWAVE_EXE=${GTKWAVE_EXE}
                    -DGTKWAVE_FOUND=${GTKWAVE_FOUND}
                    -DTB_FILE=${_tb_file}
                    -DRTL_FILES=${_rtl_str}
                    -DRTL_PKG_DIR=${RTL_PKG_DIR}
                    -DWORK_DIR=${_work_dir}
                    -DWAVE=${_wave}
                    -P "${DEV_SCRIPTS_DIR}/verilator/sim_driver.cmake"
                    WORKING_DIRECTORY "${_work_dir}"
                )

            else()
                # No simulator available — register as DISABLED so ctest -N
                # still shows the test rather than silently omitting it.
                add_test(
                    NAME ${_test}
                    COMMAND ${CMAKE_COMMAND} -E echo
                    "[SKIP] No simulator configured. Set -DSIM=vivado or -DSIM=verilator."
                )
                set_tests_properties(${_test} PROPERTIES DISABLED TRUE)
            endif()

            # --- CTest properties --------------------------------------------
            set_tests_properties(${_test} PROPERTIES
                TIMEOUT ${_timeout}
                WORKING_DIRECTORY "${_work_dir}"
                # Pass/fail determined from output regardless of exit code
                # PASS_REGULAR_EXPRESSION "\\[SIM\\] PASSED"
                # FAIL_REGULAR_EXPRESSION "\\[SIM\\] FAILED;FATAL;ERROR;xvlog:.*\\[XVLOG"
                LABELS "${_label}"
            )

            message(STATUS "[targets]   + ${_test}  (sim=${ACTIVE_SIM}  label=${_label}  timeout=${_timeout}s  wave=${_wave})")
            foreach(_f ${_rtl_files})
                message(VERBOSE "[targets]       RTL: ${_f}")
            endforeach()

        endforeach()
    endif()

    # =========================================================================
    # Part 2 — Synthesis runs
    # =========================================================================
    get_property(_all_synth GLOBAL PROPERTY ALL_SYNTH_NAMES)

    if(_all_synth)
        list(LENGTH _all_synth _scount)
        message(STATUS "[targets] Registering ${_scount} synthesis run(s)...")

        foreach(_srun ${_all_synth})

            get_property(_top GLOBAL PROPERTY SYNTH_${_srun}_TOP)
            get_property(_part GLOBAL PROPERTY SYNTH_${_srun}_PART)
            get_property(_modules GLOBAL PROPERTY SYNTH_${_srun}_MODULES)
            get_property(_xdc GLOBAL PROPERTY SYNTH_${_srun}_XDC)
            get_property(_stimeout GLOBAL PROPERTY SYNTH_${_srun}_TIMEOUT)

            # Assemble RTL files
            set(_rtl_files "")
            foreach(_m ${_modules})
                get_rtl_files(${_m} _mod_files)
                list(APPEND _rtl_files ${_mod_files})
            endforeach()
            list(REMOVE_DUPLICATES _rtl_files)
            string(REPLACE ";" "|" _rtl_str "${_rtl_files}")

            set(_swork_dir "${SYNTH_OUT_DIR}/${_srun}")
            file(MAKE_DIRECTORY "${_swork_dir}")

            if(VIVADO_FOUND)
                add_test(
                    NAME ${_srun}
                    COMMAND ${CMAKE_COMMAND}
                    -DVIVADO_EXE=${VIVADO_EXE}
                    -DTOP_MODULE=${_top}
                    -DPART=${_part}
                    -DRTL_FILES=${_rtl_str}
                    -DXDC_FILE=${_xdc}
                    -DWORK_DIR=${_swork_dir}
                    -P "${DEV_SCRIPTS_DIR}/vivado/synth_driver.cmake"
                    WORKING_DIRECTORY "${_swork_dir}"
                )
            else()
                add_test(
                    NAME ${_srun}
                    COMMAND ${CMAKE_COMMAND} -E echo
                    "[SKIP] Vivado not found — synthesis disabled."
                )
                set_tests_properties(${_srun} PROPERTIES DISABLED TRUE)
            endif()

            set_tests_properties(${_srun} PROPERTIES
                TIMEOUT ${_stimeout}
                WORKING_DIRECTORY "${_swork_dir}"
                PASS_REGULAR_EXPRESSION "\\[SYNTH\\] PASSED"
                FAIL_REGULAR_EXPRESSION "\\[SYNTH\\] FAILED;ERROR;"
                LABELS "synth"
            )

            message(STATUS "[targets]   + ${_srun}  (synth  top=${_top}  part=${_part}  timeout=${_stimeout}s)")

        endforeach()
    endif()

    # =============================================================================
    # Firmware Targets
    # =============================================================================

    message(STATUS "PYTHON3_EXE = ${Python3_EXECUTABLE}")
    message(STATUS "RISCV_OBJDUMP = ${RISCV_OBJDUMP}")
    message(STATUS "RISCV_OBJCOPY = ${RISCV_OBJCOPY}")

    get_all_firmware(_all_fw)

    if(_all_fw)

        list(LENGTH _all_fw _fw_count)
        message(STATUS "[targets] Registering ${_fw_count} firmware target(s)...")

        add_custom_target(firmware_all)

        foreach(_fw ${_all_fw})

            get_firmware_property(${_fw} SOURCES _sources)
            get_firmware_property(${_fw} LINKER _linker)
            get_firmware_property(${_fw} ARCH _arch)
            get_firmware_property(${_fw} ABI _abi)
            get_firmware_property(${_fw} DIR _fw_dir)

            set(_fw_out_dir "${_fw_dir}/out")

            file(MAKE_DIRECTORY "${_fw_out_dir}")

            add_custom_target(
                firmware_${_fw}

                COMMAND ${CMAKE_COMMAND} -E make_directory "${_fw_out_dir}"

                COMMAND ${RISCV_GCC}
                -march=${_arch}
                -mabi=${_abi}
                -nostdlib
                -T "${_linker}"
                ${_sources}
                -Wl,-Map=${_fw_out_dir}/${_fw}.map
                -o ${_fw_out_dir}/${_fw}.elf

                # COMMAND ${RISCV_OBJCOPY}
                # -O binary
                # ${_fw_out_dir}/${_fw}.elf
                # ${_fw_out_dir}/${_fw}.bin

                # COMMAND ${Python3_EXECUTABLE}
                # ${CMAKE_SOURCE_DIR}/sw/scripts/elf_to_mem.py
                # ${RISCV_OBJDUMP}
                # ${_fw_out_dir}/${_fw}.elf
                # ${_fw_out_dir}/${_fw}.mem

                COMMAND ${RISCV_OBJCOPY}
                -O verilog
                --verilog-data-width=4
                -j .text
                ${_fw_out_dir}/${_fw}.elf
                ${_fw_out_dir}/${_fw}.mem

                COMMAND ${RISCV_OBJCOPY}
                -O verilog
                --verilog-data-width=8
                -j .data --change-section-lma .data=0
                ${_fw_out_dir}/${_fw}.elf
                ${_fw_out_dir}/${_fw}.dmem

                COMMENT "Building firmware '${_fw}'"
                VERBATIM
            )

            add_dependencies(
                firmware_all
                firmware_${_fw}
            )

            add_test(
                NAME fw_${_fw}

                COMMAND ${CMAKE_COMMAND}
                --build ${CMAKE_BINARY_DIR}
                --target firmware_${_fw}
            )

            set_tests_properties(
                fw_${_fw}
                PROPERTIES
                LABELS "fw"
            )

            message(STATUS
                "[targets]   + firmware_${_fw} -> ${_fw_out_dir}"
            )

        endforeach()

    endif()

endfunction()
