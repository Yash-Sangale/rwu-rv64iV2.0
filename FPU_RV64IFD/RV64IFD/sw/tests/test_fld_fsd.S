# test_fld_fsd.S — FLD/FSD round-trip, then FCVT to verify.
# Stores 5.0 to DMEM, loads it back, converts → integer 5.
# Expected GPIO: 0x05
.section .text
.global _start
_start:
    lui   t0, 0x10001
    addi  t1, zero, 0xFF
    sd    t1, 8(t0)

    lui   a0, %hi(const_5_0)
    addi  a0, a0, %lo(const_5_0)
    fld   f0, 0(a0)             // f0 = 5.0

    // Store f0 to DMEM scratch
    lui   a1, 0x10              // DMEM_BASE = 0x1_0000
    fsd   f0, 256(a1)           // write to DMEM+256

    // Load back
    fld   f1, 256(a1)

    // Convert f1 → integer
    fcvt.l.d a2, f1, rtz

    sd    a2, 16(t0)            // GPIO.DATA

done:
    j done

.section .rodata
.align 3
const_5_0: .quad 0x4014000000000000   // IEEE 754 double 5.0
