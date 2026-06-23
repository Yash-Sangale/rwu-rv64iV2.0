.section .data
.align 3
# Constants defined in memory
val1: .double 1.0
val2: .double 2.0
res:  .double 3.0

.section .text
.global _start

_start:
    # 1. Load data into FPU registers
    la x1, val1
    fld f0, 0(x1)
    la x2, val2
    fld f1, 0(x2)
    
    # 2. Perform the operation (1.0 + 2.0)
    fadd.d f3, f0, f1
    
    # 3. Load the expected result for comparison
    la x3, res
    fld f4, 0(x3)
    
    # 4. Self-Checking Logic
    # Use feq.d to set an integer register to 1 if equal, 0 if not
    feq.d x5, f3, f4
    
    # If x5 is 0 (false), it means the FPU result was incorrect
    beqz x5, fail_test
    
pass_test:
    li x10, 0              # x10 = 0 indicates PASS
    j end_loop

fail_test:
    li x10, 1              # x10 = 1 indicates FAIL

end_loop:
    j end_loop             # Simulation/Hardware testbench monitors this loop