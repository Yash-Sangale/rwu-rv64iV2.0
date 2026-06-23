# test_addi.S — result = 2 + 4 = 6, written to GPIO.DATA[7:0]
# Expected GPIO read: 0x06
.section .text
.global _start
_start:
    // Set GPIO[7:0] as outputs: GPIO.DIR = 0xFF
    lui   t0, 0x10001              // t0 = 0x1000_0100 (GPIO0_BASE)
    addi  t1, zero, 0xFF
    sd    t1, 8(t0)                // GPIO.DIR offset 0x08

    // Compute result
    addi  x1, zero, 2
    addi  x1, x1,   4             // x1 = 6

    // Write to GPIO.DATA (offset 0x10)
    sd    x1, 16(t0)

done:
    j done
