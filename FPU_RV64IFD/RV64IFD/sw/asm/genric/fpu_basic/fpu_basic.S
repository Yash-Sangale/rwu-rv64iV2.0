.section .data
.align 3
const_one:   .double 1.0
const_two:   .double 2.0
const_four:  .double 4.0
const_three: .double 3.0  # Added missing constant

.section .text
.global _start

_start:
    # 1. Load Operands
    la x1, const_one    # Use 'la' pseudo-instruction for readability
    fld f0, 0(x1)
    la x4, const_two
    fld f1, 0(x4)
    la x5, const_four
    fld f2, 0(x5)
    la x6, const_three
    fld f10, 0(x6)      # Used for comparing with f3

    # 2. Execute FPU Operations
    fadd.d  f3, f0, f1   # 3.0
    fsub.d  f4, f2, f1   # 2.0
    fmul.d  f5, f1, f1   # 4.0
    fdiv.d  f6, f2, f1   # 2.0
    fsqrt.d f7, f2       # 2.0

    # 3. Validation Logic
    # We compare results against known values (f1 is 2.0, f2 is 4.0, f10 is 3.0)
    
    # Check f3 (3.0) == f10 (3.0)
    feq.d x7, f3, f10
    beqz x7, fail_test

    # Check f4 (2.0) == f1 (2.0)
    feq.d x7, f4, f1
    beqz x7, fail_test

    # Check f5 (4.0) == f2 (4.0)
    feq.d x7, f5, f2
    beqz x7, fail_test

    # Check f6 (2.0) == f1 (2.0)
    feq.d x7, f6, f1
    beqz x7, fail_test

    # Check f7 (2.0) == f1 (2.0)
    feq.d x7, f7, f1
    beqz x7, fail_test

pass_test:
    li x10, 0
    j end_loop

fail_test:
    li x10, 1

end_loop:
    j end_loop