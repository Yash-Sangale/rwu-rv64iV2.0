register_firmware(
    NAME fpu_sanity

    SOURCES
    ${CMAKE_CURRENT_SOURCE_DIR}/fpu_sanity.S

    LINKER
    ${CMAKE_SOURCE_DIR}/sw/linker.ld

    ARCH
    rv64ifd_zicsr

    ABI
    lp64d
)
