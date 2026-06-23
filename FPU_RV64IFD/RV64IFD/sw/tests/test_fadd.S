# test_fadd.S — FADD.D: 1.0 + 2.0 = 3.0
# FCVT.L.D converts 3.0 → integer 3, written to GPIO.DATA.
# Expected GPIO: 0x03
.section .text
.global _start
_start:
    lui   t0, 0x10001          // GPIO0_BASE
    addi  t1, zero, 0xFF
    sd    t1, 8(t0)            // GPIO.DIR[7:0] = outputs

    // Load 1.0 into f0
    lui   a0, %hi(const_1_0)
    addi  a0, a0, %lo(const_1_0)
    fld   f0, 0(a0)

    // Load 2.0 into f1
    lui   a0, %hi(const_2_0)
    addi  a0, a0, %lo(const_2_0)
    fld   f1, 0(a0)

    // f2 = f0 + f1 = 3.0
    fadd.d f2, f0, f1

    // Convert 3.0 → integer
    fcvt.l.d a1, f2, rtz

    // Write to GPIO
    sd    a1, 16(t0)

done:
    j done

.section .rodata
.align 3
const_1_0: .quad 0x3FF0000000000000   // IEEE 754 double 1.0
const_2_0: .quad 0x4000000000000000   // IEEE 754 double 2.0
