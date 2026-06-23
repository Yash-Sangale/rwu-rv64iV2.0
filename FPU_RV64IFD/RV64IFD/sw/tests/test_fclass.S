# test_fclass.S — FCLASS.D on +infinity.
# Expected result: bit[7] = 1 → integer 0x80.
# Expected GPIO: 0x80
.section .text
.global _start
_start:
    lui   t0, 0x10001
    addi  t1, zero, 0xFF
    sd    t1, 8(t0)

    lui   a0, %hi(const_inf)
    addi  a0, a0, %lo(const_inf)
    fld   f0, 0(a0)

    fclass.d a1, f0             // bit[7]=+inf → 0x80

    sd    a1, 16(t0)

done:
    j done

.section .rodata
.align 3
const_inf: .quad 0x7FF0000000000000   // +infinity
