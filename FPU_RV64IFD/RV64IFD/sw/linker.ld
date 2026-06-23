OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
    IMEM (rx)  : ORIGIN = 0x00000000, LENGTH = 64K
    DMEM (rwx) : ORIGIN = 0x00010000, LENGTH = 64K
}

SECTIONS {
    .text   : { *(.text*)   } > IMEM
    .rodata : { *(.rodata*) } > IMEM
    .data   : { *(.data*)   } > DMEM AT > IMEM
    .bss    : { *(.bss*)  PROVIDE(__bss_end = .); } > DMEM
    _stack_top = ORIGIN(DMEM) + LENGTH(DMEM);
}
