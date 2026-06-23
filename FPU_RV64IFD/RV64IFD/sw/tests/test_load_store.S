# test_load_store.S — store 0xAB to DMEM then load it back, write to GPIO
# Expected GPIO: 0xAB
.section .text
.global _start
_start:
    lui   t0, 0x10001             // GPIO0_BASE
    addi  t1, zero, 0xFF
    sd    t1, 8(t0)               // GPIO.DIR

    // Store 0xAB to DMEM (base 0x0001_0000)
    lui   a0, 0x10                // a0 = 0x1_0000 = DMEM_BASE
    addi  a1, zero, 0xAB         // cannot do addi directly with 0xAB
    sb    a1, 0(a0)               // store byte

    // Load it back
    lb    a2, 0(a0)               // load byte (sign-extended, but 0xAB < 0x80... wait 0xAB = 171 > 127)
    lbu   a2, 0(a0)               // use unsigned load to keep 0xAB intact

    sd    a2, 16(t0)              // GPIO.DATA

done:
    j done
