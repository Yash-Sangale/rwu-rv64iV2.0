register_firmware(
    NAME alu_sanity

    SOURCES
    ${CMAKE_CURRENT_SOURCE_DIR}/alu_sanity.S

    LINKER
    ${CMAKE_SOURCE_DIR}/sw/linker.ld

    ARCH
    rv64ifd_zicsr

    ABI
    lp64d
)
