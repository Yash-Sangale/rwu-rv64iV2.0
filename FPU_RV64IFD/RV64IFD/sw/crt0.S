.section .text
.global _start

_start:
    # Set up stack pointer here if you have memory (e.g., li sp, 0x8000)
    call main        # Call the C main function
                     # When main returns, its return value is already in x10 (a0)
end_loop:
    j end_loop       # Spin loop for testbench