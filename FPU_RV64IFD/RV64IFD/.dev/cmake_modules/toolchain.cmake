# =============================================================================
# toolchain.cmake — simulator and tool detection
#
# Detects all tools needed for simulation, synthesis, and firmware:
#   - Vivado  (xsim backend — FPGA synthesis + simulation)
#   - Verilator  (open-source simulation backend, preferred for CI)
#   - GTKWave    (waveform viewer for Verilator .vcd output)
#   - RISC-V GNU toolchain  (firmware cross-compilation)
#   - Git, Python3, Ninja   (infrastructure)
#
# Design rules:
#   - NEVER issues FATAL_ERROR — a missing tool is only fatal when a target
#     that actually needs it runs.
#   - All results stored as CACHE INTERNAL so every cmake module sees them.
#   - Works identically on Windows and Linux (no platform-specific shell calls).
# =============================================================================

# =============================================================================
# Vivado — build installation hint list for both platforms
# =============================================================================
set(_vivado_hints "")

if(WIN32)
    foreach(_year 2024 2023 2022 2021 2020)
        foreach(_ver 2 1 0)
            foreach(_drive "C" "D" "E")
                list(APPEND _vivado_hints
                    "${_drive}:/Xilinx/Vivado/${_year}.${_ver}/bin"
                    "${_drive}:/AMD/Vivado/${_year}.${_ver}/bin"
                )
            endforeach()
        endforeach()
    endforeach()
else()
    # Linux — covers the four most common installation prefixes
    foreach(_year 2024 2023 2022 2021 2020)
        foreach(_ver 2 1 0)
            list(APPEND _vivado_hints
                "/opt/Xilinx/Vivado/${_year}.${_ver}/bin"
                "/opt/AMD/Vivado/${_year}.${_ver}/bin"
                "/tools/Xilinx/Vivado/${_year}.${_ver}/bin"
                "/usr/local/Xilinx/Vivado/${_year}.${_ver}/bin"
                "$ENV{HOME}/Xilinx/Vivado/${_year}.${_ver}/bin"
                "$ENV{HOME}/tools/Xilinx/Vivado/${_year}.${_ver}/bin"
            )
        endforeach()
    endforeach()
endif()

# -----------------------------------------------------------------------------
# Detect Vivado
# -----------------------------------------------------------------------------
find_program(VIVADO_EXE
    NAMES vivado vivado.bat
    HINTS ${_vivado_hints}
    DOC "Vivado executable"
)

if(VIVADO_EXE)
    get_filename_component(_vbin "${VIVADO_EXE}" DIRECTORY)

    # xvlog / xelab / xsim live next to vivado — REQUIRED once vivado is found
    find_program(XVLOG_EXE NAMES xvlog.bat HINTS "${_vbin}" NO_DEFAULT_PATH REQUIRED)
    find_program(XELAB_EXE NAMES xelab.bat HINTS "${_vbin}" NO_DEFAULT_PATH REQUIRED)
    find_program(XSIM_EXE NAMES xsim.bat HINTS "${_vbin}" NO_DEFAULT_PATH REQUIRED)

    # Cache all paths so cmake -P scripts can read them
    set(VIVADO_EXE "${VIVADO_EXE}" CACHE INTERNAL "Vivado executable")
    set(XVLOG_EXE "${XVLOG_EXE}" CACHE INTERNAL "xvlog executable")
    set(XELAB_EXE "${XELAB_EXE}" CACHE INTERNAL "xelab executable")
    set(XSIM_EXE "${XSIM_EXE}" CACHE INTERNAL "xsim  executable")
    set(VIVADO_FOUND TRUE CACHE INTERNAL "Vivado detected")

    # Derive the Vivado version from the directory name (e.g. 2024.2)
    get_filename_component(_vivado_bin_parent "${_vbin}" DIRECTORY)
    get_filename_component(VIVADO_VERSION "${_vivado_bin_parent}" NAME)
    set(VIVADO_VERSION "${VIVADO_VERSION}" CACHE INTERNAL "Vivado version string")
    # Derive XILINX_VIVADO install root — needed by xvlog/xelab/xsim.bat
    # Path is: <install>/Vivado/<version>/bin/vivado  → go up two levels
    get_filename_component(XILINX_VIVADO "${_vbin}/.." ABSOLUTE)
    set(XILINX_VIVADO "${XILINX_VIVADO}" CACHE INTERNAL "Vivado install root for XILINX_VIVADO env var")
    message(STATUS "[toolchain] XILINX_VIVADO: ${XILINX_VIVADO}")

    message(STATUS "[toolchain] Vivado   : ${VIVADO_EXE}  (v${VIVADO_VERSION})")
    message(STATUS "[toolchain] xvlog    : ${XVLOG_EXE}")
    message(STATUS "[toolchain] xelab    : ${XELAB_EXE}")
    message(STATUS "[toolchain] xsim     : ${XSIM_EXE}")
else()
    set(VIVADO_FOUND FALSE CACHE INTERNAL "Vivado detected")
    set(VIVADO_VERSION "" CACHE INTERNAL "Vivado version string")
    message(STATUS "[toolchain] Vivado   : NOT FOUND")
    message(STATUS "            To fix:  add <Vivado>/bin to PATH, or")
    message(STATUS "                     pass -DVIVADO_EXE=<path> to cmake")
endif()

# =============================================================================
# Verilator
# =============================================================================
set(_verilator_hints "")
if(NOT WIN32)
    list(APPEND _verilator_hints
        "/usr/bin" "/usr/local/bin"
        "/opt/verilator/bin"
        "$ENV{HOME}/.local/bin"
    )
endif()

find_program(VERILATOR_EXE
    NAMES verilator
    HINTS ${_verilator_hints}
    DOC "Verilator executable"
)

if(VERILATOR_EXE)
    # Ask verilator for its include root (needed to compile the generated C++)
    execute_process(
        COMMAND "${VERILATOR_EXE}" --getenv VERILATOR_ROOT
        OUTPUT_VARIABLE VERILATOR_ROOT
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET
        RESULT_VARIABLE _vroot_rc
    )
    if(NOT _vroot_rc EQUAL 0 OR NOT VERILATOR_ROOT)
        # Fallback: derive from binary location
        get_filename_component(_vlt_bin "${VERILATOR_EXE}" DIRECTORY)
        get_filename_component(VERILATOR_ROOT "${_vlt_bin}/.." ABSOLUTE)
    endif()
    set(VERILATOR_ROOT "${VERILATOR_ROOT}" CACHE INTERNAL "Verilator install root")
    set(VERILATOR_FOUND TRUE CACHE INTERNAL "Verilator detected")
    message(STATUS "[toolchain] Verilator : ${VERILATOR_EXE}")
    message(STATUS "[toolchain]   root    : ${VERILATOR_ROOT}")
else()
    set(VERILATOR_FOUND FALSE CACHE INTERNAL "Verilator detected")
    message(STATUS "[toolchain] Verilator : NOT FOUND  (apt install verilator / brew install verilator)")
endif()

# =============================================================================
# GTKWave — waveform viewer for Verilator .vcd output
# =============================================================================
find_program(GTKWAVE_EXE
    NAMES gtkwave gtkwave.exe
    DOC "GTKWave waveform viewer"
)
if(GTKWAVE_EXE)
    set(GTKWAVE_FOUND TRUE CACHE INTERNAL "GTKWave detected")
    message(STATUS "[toolchain] GTKWave  : ${GTKWAVE_EXE}")
else()
    set(GTKWAVE_FOUND FALSE CACHE INTERNAL "GTKWave detected")
    message(STATUS "[toolchain] GTKWave  : NOT FOUND  (apt install gtkwave / brew install gtkwave)")
endif()

# =============================================================================
# RISC-V GNU Toolchain — firmware cross-compilation
# =============================================================================
set(_riscv_hints "")
if(WIN32)
    if(LOCAL_RISCV_TOOLCHAIN)
        list(APPEND _riscv_hints "${LOCAL_RISCV_TOOLCHAIN}")
        message(STATUS "[toolchain] LOCAL_RISCV_TOOLCHAIN = ${LOCAL_RISCV_TOOLCHAIN}")
    else()
        message(STATUS "[toolchain] RISC-V GCC: ${LOCAL_RISCV_TOOLCHAIN} Not  Defined")
    endif()

    foreach(_drive "C" "D")
        list(APPEND _riscv_hints
            "${_drive}:/riscv64-unknown-elf/bin"
            "${_drive}:/riscv/bin"
            "${_drive}:/SysGCC/risc-v/bin"
        )
    endforeach()
else()
    list(APPEND _riscv_hints
        "/usr/bin" "/usr/local/bin"
        "/opt/riscv/bin"
        "$ENV{HOME}/riscv/bin"
        "${CMAKE_BINARY_DIR}/toolchains/riscv/bin"
    )
endif()

find_program(RISCV_GCC
    NAMES
    riscv-none-elf-gcc
    riscv64-unknown-elf-gcc
    riscv64-linux-gnu-gcc
    riscv32-unknown-elf-gcc
    HINTS ${_riscv_hints}
    DOC "RISC-V GCC cross-compiler"
)
if(RISCV_GCC)
    set(RISCV_TOOLCHAIN_FOUND TRUE CACHE INTERNAL "RISC-V toolchain detected")
    get_filename_component(_riscv_bin "${RISCV_GCC}" DIRECTORY)
    find_program(RISCV_OBJCOPY
        NAMES
        riscv-none-elf-objcopy
        riscv64-unknown-elf-objcopy
        riscv64-linux-gnu-objcopy
        HINTS "${_riscv_bin}"
        NO_DEFAULT_PATH)
    find_program(RISCV_OBJDUMP
        NAMES
        riscv-none-elf-objdump
        riscv64-unknown-elf-objdump
        riscv64-linux-gnu-objdump
        HINTS "${_riscv_bin}" NO_DEFAULT_PATH)
    message(STATUS "[toolchain] RISC-V GCC: ${RISCV_GCC}")
else()
    set(RISCV_TOOLCHAIN_FOUND FALSE CACHE INTERNAL "RISC-V toolchain detected")
    message(STATUS "[toolchain] RISC-V GCC: NOT FOUND  (see provision/fetch_riscv_gcc.cmake or -DAUTO_PROVISION_RISCV=ON)")
endif()

# =============================================================================
# Git
# =============================================================================
find_package(Git QUIET)
if(Git_FOUND OR GIT_FOUND)
    message(STATUS "[toolchain] Git      : ${GIT_EXECUTABLE}")
else()
    message(STATUS "[toolchain] Git      : NOT FOUND  (install from https://git-scm.com)")
endif()

# =============================================================================
# Python 3
# =============================================================================
find_package(Python3 QUIET COMPONENTS Interpreter)
if(Python3_FOUND)
    message(STATUS "[toolchain] Python3  : ${Python3_EXECUTABLE}  (v${Python3_VERSION})")
else()
    message(STATUS "[toolchain] Python3  : NOT FOUND  (install from https://python.org)")
endif()

# =============================================================================
# Ninja (generator check — informational only)
# =============================================================================
find_program(NINJA_EXE NAMES ninja ninja.exe DOC "Ninja build tool")
if(NINJA_EXE)
    message(STATUS "[toolchain] Ninja    : ${NINJA_EXE}")
else()
    message(STATUS "[toolchain] Ninja    : NOT FOUND  (cmake --install ninja, or use -G \"Unix Makefiles\")")
endif()

# =============================================================================
# Determine active simulator
# =============================================================================
# SIM is set either by CMakePresets.json or by -DSIM=<value> on the command line.
# Default is vivado.  toolchain.cmake re-declares it so cmake-gui shows the
# dropdown even when the user has not passed -DSIM.
set(SIM "vivado" CACHE STRING "Simulator backend (vivado | verilator)")
set_property(CACHE SIM PROPERTY STRINGS "vivado" "verilator")

if(SIM STREQUAL "vivado")
    if(VIVADO_FOUND)
        set(ACTIVE_SIM "vivado" CACHE INTERNAL "Active simulator backend")
    else()
        message(WARNING "[toolchain] SIM=vivado but Vivado not found — tests will be DISABLED.")
        set(ACTIVE_SIM "none" CACHE INTERNAL "Active simulator backend")
    endif()
elseif(SIM STREQUAL "verilator")
    if(VERILATOR_FOUND)
        set(ACTIVE_SIM "verilator" CACHE INTERNAL "Active simulator backend")
    else()
        message(WARNING "[toolchain] SIM=verilator but Verilator not found — tests will be DISABLED.")
        set(ACTIVE_SIM "none" CACHE INTERNAL "Active simulator backend")
    endif()
else()
    message(WARNING "[toolchain] Unknown SIM='${SIM}'. Valid values: vivado, verilator.")
    set(ACTIVE_SIM "none" CACHE INTERNAL "Active simulator backend")
endif()

message(STATUS "[toolchain] Active SIM: ${ACTIVE_SIM}")

# =============================================================================
# Common paths used by all drivers
# =============================================================================

# All simulation artefacts go here — never inside the source tree
set(SIM_OUT_DIR "${CMAKE_BINARY_DIR}/sim" CACHE INTERNAL "Simulation output directory")
file(MAKE_DIRECTORY "${SIM_OUT_DIR}")

# All synthesis artefacts go here
set(SYNTH_OUT_DIR "${CMAKE_BINARY_DIR}/synth" CACHE INTERNAL "Synthesis output directory")
file(MAKE_DIRECTORY "${SYNTH_OUT_DIR}")

# Dev scripts root — used by targets.cmake to locate drivers
set(DEV_SCRIPTS_DIR "${CMAKE_SOURCE_DIR}/.dev/scripts" CACHE INTERNAL "Dev scripts root")

# =============================================================================
# Optional auto-provision hook
# =============================================================================
include("${CMAKE_CURRENT_LIST_DIR}/../provision/fetch_riscv_gcc.cmake" OPTIONAL)

# =============================================================================
# Tool summary table  (always printed at end of configure)
# =============================================================================
include("${CMAKE_CURRENT_LIST_DIR}/check_tools.cmake")
