CROSS   ?= riscv64-unknown-elf
AS      := $(CROSS)-as
LD      := $(CROSS)-ld
OBJCOPY := $(CROSS)-objcopy
OBJDUMP := $(CROSS)-objdump

ASFLAGS := -march=rv64im -mabi=lp64 -g
LDSCRIPT := ../linker.ld

TESTS := test_addi test_lui test_load_store

all: $(addsuffix .hex, $(TESTS))

%.o: %.S
	$(AS) $(ASFLAGS) -o $@ $<

%.elf: %.o
	$(LD) -T $(LDSCRIPT) -o $@ $<

%.hex: %.elf
	$(OBJCOPY) -O verilog $< $@
	@echo "[OK] $@"

%.dis: %.elf
	$(OBJDUMP) -d $< > $@

clean:
	rm -f *.o *.elf *.hex *.dis

TESTS_FP := test_fadd test_fld_fsd test_fclass

fp: $(addsuffix .hex, $(TESTS_FP))
