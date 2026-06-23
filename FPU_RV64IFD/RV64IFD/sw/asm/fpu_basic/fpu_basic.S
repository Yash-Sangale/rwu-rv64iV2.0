.section .data
.align 3
const_one:  .double 1.0
const_two:  .double 2.0
const_four: .double 4.0

.section .text
.global _start

_start:
    # -------------------------------------------------------------------------
    # 1. Load Operands via pre-calculated integer register base paths
    # -------------------------------------------------------------------------
    lui     x1, %hi(const_one)
    addi    x1, x1, %lo(const_one)   # Base address for constants
    fld     f0, 0(x1)                # Load 1.0 into f0

    lui     x4, %hi(const_two)
    addi    x4, x4, %lo(const_two)   
    fld     f1, 0(x4)                # Load 2.0 into f1

    lui     x5, %hi(const_four)
    addi    x5, x5, %lo(const_four)  
    fld     f2, 0(x5)                # Load 4.0 into f2

    # -------------------------------------------------------------------------
    # 2. Execute Core FPU Pipeline Arithmetic
    # -------------------------------------------------------------------------
    fadd.d  f3, f0, f1          # 1.0 + 2.0 = 3.0   (0x4008000000000000)
    fsub.d  f4, f2, f1          # 4.0 - 2.0 = 2.0   (0x4000000000000000)
    fmul.d  f5, f1, f1          # 2.0 * 2.0 = 4.0   (0x4010000000000000)
    fdiv.d  f6, f2, f1          # 4.0 / 2.0 = 2.0   (0x4000000000000000)
    fsqrt.d f7, f2              # sqrt(4.0) = 2.0   (0x4000000000000000)

success_spin:
    addi    x0, x0, 0           # Pure execution marker hint for the testbench!
    j       success_spin        # Infinite jump loop back to previous line