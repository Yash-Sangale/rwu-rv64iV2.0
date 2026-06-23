# RV64IFD_Zicsr Verification and Firmware Testing Strategy

## 1. Purpose

This document defines the verification methodology for the RV64IFD_Zicsr processor core.

The goals are:

* Verify correctness of all supported instructions.
* Support both Assembly and C firmware testing.
* Minimize testbench modifications when adding new tests.
* Enable future integration with RISC-V compliance suites.
* Enable automated regression execution using CTest.

---

# 2. Verification Philosophy

## 2.1 Current Approach

Current testbench behavior:

* Load a specific firmware image.
* Wait until firmware reaches an infinite loop.
* Directly inspect architectural registers.
* Compare against hardcoded expected values.

Example:

```text
x1 = 40
x2 = 20
x3 = 60
```

This approach is useful for early bring-up but does not scale.

Every new firmware requires modifying the testbench.

---

## 2.2 Target Approach

Firmware becomes self-checking.

The processor executes tests and reports:

```text
PASS
or
FAIL
```

to the testbench.

The testbench becomes generic and independent of individual test cases.

---

# 3. Testbench MMIO Interface

A simulation-only MMIO peripheral shall be reserved.

## 3.1 Address Map

```text
TESTBENCH_BASE = 0x1000F000

0x1000F000 TEST_STATUS
0x1000F008 TEST_SIGNATURE
0x1000F010 TEST_DATA0
0x1000F018 TEST_DATA1
```

---

## 3.2 TEST_STATUS

Values:

```text
0 = Running
1 = Pass
2 = Fail
```

Firmware writes one of these values when execution completes.

---

## 3.3 TEST_SIGNATURE

Optional register.

Used to report:

* Computed result
* Failure code
* Exception cause
* Debug information

Example:

```text
Expected:
60

Actual:
58
```

Firmware may write:

```text
TEST_SIGNATURE = 58
```

before reporting failure.

---

# 4. Generic Testbench Architecture

The testbench shall:

1. Load firmware.
2. Release reset.
3. Monitor TEST_STATUS MMIO writes.
4. Report PASS or FAIL.
5. End simulation.

No instruction-specific checks shall exist inside the testbench.

---

# 5. Assembly Testing Framework

## 5.1 Test Macros

A common file:

```assembly
test_macros.S
```

shall contain reusable helper macros.

---

## 5.2 PASS Macro

```assembly
.macro TEST_PASS

    li t0, 0x1000F000
    li t1, 1
    sd t1, 0(t0)

1:
    j 1b

.endm
```

---

## 5.3 FAIL Macro

```assembly
.macro TEST_FAIL

    li t0, 0x1000F000
    li t1, 2
    sd t1, 0(t0)

1:
    j 1b

.endm
```

---

## 5.4 ASSERT_EQ Macro

```assembly
.macro ASSERT_EQ reg,val

    li t6,\val
    bne \reg,t6,fail

.endm
```

---

# 6. Example Integer Test

File:

```text
rv64i/add.S
```

Example:

```assembly
.include "test_macros.S"

.section .text
.global _start

_start:

    li x1,40
    li x2,20

    add x3,x1,x2

    ASSERT_EQ x3,60

    TEST_PASS

fail:
    TEST_FAIL
```

---

# 7. Example Floating Point Test

File:

```text
rv64d/fadd_d.S
```

Example:

```assembly
fld f0, one
fld f1, two

fadd.d f2,f0,f1

# Compare against expected value

TEST_PASS
```

---

# 8. Signature-Based Debugging

Example:

```assembly
li t0,0x1000F008
sd x3,0(t0)

TEST_FAIL
```

Testbench output:

```text
FAIL

Signature = 58
Expected  = 60
```

This greatly simplifies debugging.

---

# 9. C Firmware Support

The same framework shall support C programs.

---

## 9.1 Testbench Header

File:

```text
common/tb.h
```

```c
#ifndef TB_H
#define TB_H

#define TB_STATUS \
(*(volatile unsigned long*)0x1000F000)

#define TB_SIGNATURE \
(*(volatile unsigned long*)0x1000F008)

#define TEST_PASS()         \
do {                        \
    TB_STATUS = 1;          \
    while(1);               \
} while(0)

#define TEST_FAIL()         \
do {                        \
    TB_STATUS = 2;          \
    while(1);               \
} while(0)

#endif
```

---

## 9.2 Example C Test

```c
#include "tb.h"

int main(void)
{
    long a = 40;
    long b = 20;

    long c = a + b;

    if(c != 60)
        TEST_FAIL();

    TEST_PASS();
}
```

The testbench remains unchanged.

---

# 10. Startup Code

A common startup file shall initialize the processor before calling main().

File:

```text
common/crt0.S
```

Example:

```assembly
.section .text
.global _start

_start:

    la sp,_stack_top

    call main

hang:
    j hang
```

---

# 11. Linker Script

Current linker script:

```ld
IMEM = 0x00000000
DMEM = 0x00010000
```

matches the RTL memory map.

No modifications are required for the basic framework.

---

# 12. Test Categories

## RV64I

```text
LUI
AUIPC

ADDI
SLTI
SLTIU
XORI
ORI
ANDI

ADD
SUB
SLL
SLT
SLTU
XOR
SRL
SRA
OR
AND

LB
LH
LW
LD
LBU
LHU
LWU

SB
SH
SW
SD

BEQ
BNE
BLT
BGE
BLTU
BGEU

JAL
JALR
```

---

## RV64 Extensions

```text
ADDIW
ADDW
SUBW
SLLW
SRLW
SRAW
```

---

## RV64F

```text
FLW
FSW

FADD.S
FSUB.S
FMUL.S
FDIV.S
FSQRT.S

FCLASS.S
FEQ.S
FLT.S
FLE.S
```

---

## RV64D

```text
FLD
FSD

FADD.D
FSUB.D
FMUL.D
FDIV.D
FSQRT.D

FCLASS.D
FEQ.D
FLT.D
FLE.D
```

---

## Zicsr

```text
CSRRW
CSRRS
CSRRC

CSRRWI
CSRRSI
CSRRCI
```

---

# 13. Regression Structure

```text
sw/

common/
├── crt0.S
├── tb.h
└── test_macros.S

asm/

├── rv64i/
├── rv64f/
├── rv64d/
└── csr/

c/

├── basic/
├── csr/
└── fpu/
```

---

# 14. Automated Build Flow

```text
Assembly/C Source
        │
        ▼
Compiler
        │
        ▼
ELF
        │
        ▼
objcopy
        │
        ▼
BIN
        │
        ▼
mem_gen.py
        │
        ├── firmware.mem
        └── firmware.dmem
```

---

# 15. Automated Regression Flow

```text
Build Test
      │
      ▼
Launch Simulator
      │
      ▼
Run Firmware
      │
      ▼
Monitor TEST_STATUS
      │
      ├── PASS
      │
      └── FAIL
```

The same infrastructure shall be used for:

* Assembly instruction tests
* C firmware tests
* FPU tests
* CSR tests
* Future compliance suites

without modifying the testbench.
