.section .text
.global _start

_start:

    li x1, 40
    li x2, 20

    add x3, x1, x2

loop:
    j loop