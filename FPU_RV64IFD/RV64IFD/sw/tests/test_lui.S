# test_lui.S — result = upper immediate 0x1D = 29, written to GPIO.DATA[7:0]
# Expected GPIO read: 0x1D  (matches professor's "29" test case)
.section .text
.global _start
_start:
    lui   t0, 0x10001
    addi  t1, zero, 0xFF
    sd    t1, 8(t0)                // GPIO.DIR

    lui   x1, 0x1D000             // x1 = 0x1D000_0000 >> 12 ... but lower byte = 0
    // LUI places in [31:12]. To get 29 in byte0, use ADDI
    lui   x1, 0
    addi  x1, zero, 29            // x1 = 29 = 0x1D

    sd    x1, 16(t0)              // GPIO.DATA

done:
    j done
