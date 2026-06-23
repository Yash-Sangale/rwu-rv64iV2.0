# =============================================================================
# provision/fetch_riscv_gcc.cmake — optional RISC-V GNU toolchain download
#
# Included automatically by toolchain.cmake when RISCV_TOOLCHAIN_FOUND=FALSE.
# Does nothing unless the user explicitly opts in with -DAUTO_PROVISION_RISCV=ON.
#
# Usage:
#   cmake --preset vivado -DAUTO_PROVISION_RISCV=ON
#
# What it does:
#   1. Downloads the nightly pre-built riscv64-unknown-elf toolchain tarball
#      from github.com/riscv-collab/riscv-gnu-toolchain releases.
#   2. Extracts it to ${CMAKE_BINARY_DIR}/toolchains/riscv/
#   3. Re-runs find_program(RISCV_GCC) against that directory.
#   4. Sets RISCV_TOOLCHAIN_FOUND so check_tools.cmake shows [OK].
#
# The download is skipped on subsequent cmake runs if the binary already exists.
# =============================================================================

option(AUTO_PROVISION_RISCV
    "Download and install the RISC-V GNU toolchain if not found on PATH"
    OFF
)

if(RISCV_TOOLCHAIN_FOUND OR NOT AUTO_PROVISION_RISCV)
    return()
endif()

# =============================================================================
# Configuration
# =============================================================================
set(_riscv_tag     "2024.04.12")
set(_install_dir   "${CMAKE_BINARY_DIR}/toolchains/riscv")
set(_tarball_dir   "${CMAKE_BINARY_DIR}/toolchains/downloads")

if(WIN32)
    # Windows: use the Ubuntu-22.04 tarball (works via WSL) or the mingw build
    set(_tarball_name "riscv64-elf-ubuntu-22.04-gcc-nightly-${_riscv_tag}-nightly.tar.gz")
else()
    # Linux: detect arch
    execute_process(COMMAND uname -m
        OUTPUT_VARIABLE _arch OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
    if(_arch MATCHES "aarch64")
        set(_tarball_name "riscv64-elf-ubuntu-22.04-gcc-nightly-${_riscv_tag}-nightly.tar.gz")
    else()
        set(_tarball_name "riscv64-elf-ubuntu-22.04-gcc-nightly-${_riscv_tag}-nightly.tar.gz")
    endif()
endif()

set(_url "https://github.com/riscv-collab/riscv-gnu-toolchain/releases/download/${_riscv_tag}/${_tarball_name}")
set(_tarball_path "${_tarball_dir}/${_tarball_name}")

file(MAKE_DIRECTORY "${_install_dir}")
file(MAKE_DIRECTORY "${_tarball_dir}")

# =============================================================================
# Skip if already provisioned
# =============================================================================
find_program(_existing_gcc
    NAMES riscv64-unknown-elf-gcc
    HINTS "${_install_dir}/bin"
    NO_DEFAULT_PATH
    NO_CACHE
)
if(_existing_gcc)
    message(STATUS "[provision] RISC-V GCC already provisioned: ${_existing_gcc}")
    set(RISCV_GCC               "${_existing_gcc}"  CACHE INTERNAL "RISC-V GCC cross-compiler")
    set(RISCV_TOOLCHAIN_FOUND   TRUE                CACHE INTERNAL "RISC-V toolchain detected")
    return()
endif()

# =============================================================================
# Download
# =============================================================================
if(NOT EXISTS "${_tarball_path}")
    message(STATUS "[provision] Downloading RISC-V GNU toolchain ${_riscv_tag} ...")
    message(STATUS "[provision] URL: ${_url}")

    file(DOWNLOAD
        "${_url}"
        "${_tarball_path}"
        SHOW_PROGRESS
        TLS_VERIFY ON
        STATUS _dl_status
    )
    list(GET _dl_status 0 _dl_rc)
    list(GET _dl_status 1 _dl_msg)

    if(NOT _dl_rc EQUAL 0)
        message(WARNING
            "[provision] Download failed: ${_dl_msg}\n"
            "  Install the RISC-V toolchain manually and re-run cmake.\n"
            "  Manual install guide: https://github.com/riscv-collab/riscv-gnu-toolchain"
        )
        return()
    endif()
    message(STATUS "[provision] Download complete.")
else()
    message(STATUS "[provision] Using cached tarball: ${_tarball_path}")
endif()

# =============================================================================
# Extract
# =============================================================================
message(STATUS "[provision] Extracting to ${_install_dir} ...")

file(ARCHIVE_EXTRACT
    INPUT       "${_tarball_path}"
    DESTINATION "${_install_dir}"
)

# =============================================================================
# Verify and register
# =============================================================================
find_program(RISCV_GCC
    NAMES riscv64-unknown-elf-gcc
    HINTS "${_install_dir}/bin"
          "${_install_dir}/riscv/bin"
    NO_DEFAULT_PATH
)

if(RISCV_GCC)
    set(RISCV_TOOLCHAIN_FOUND TRUE CACHE INTERNAL "RISC-V toolchain detected")
    # Also find companion tools
    get_filename_component(_riscv_bin "${RISCV_GCC}" DIRECTORY)
    find_program(RISCV_OBJCOPY NAMES riscv64-unknown-elf-objcopy HINTS "${_riscv_bin}" NO_DEFAULT_PATH)
    find_program(RISCV_OBJDUMP NAMES riscv64-unknown-elf-objdump HINTS "${_riscv_bin}" NO_DEFAULT_PATH)
    message(STATUS "[provision] RISC-V GCC installed successfully: ${RISCV_GCC}")
else()
    message(WARNING
        "[provision] Extraction succeeded but riscv64-unknown-elf-gcc not found in ${_install_dir}.\n"
        "  The tarball layout may have changed.  Check ${_install_dir} manually."
    )
endif()
