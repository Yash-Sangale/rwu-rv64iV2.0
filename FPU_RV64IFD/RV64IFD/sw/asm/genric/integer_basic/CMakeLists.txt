register_firmware(
    NAME integer_basic

    SOURCES
    ${CMAKE_CURRENT_SOURCE_DIR}/integer_basic.S

    LINKER
    ${CMAKE_SOURCE_DIR}/sw/linker.ld

    ARCH
    rv64ifd_zicsr

    ABI
    lp64d
)
