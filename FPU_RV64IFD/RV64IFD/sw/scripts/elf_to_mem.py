#!/usr/bin/env python3

import re
import subprocess
import sys
from pathlib import Path

print("ELF_TO_MEM STARTED")
print(sys.argv)

def main():
    if len(sys.argv) != 4:
        print( "Usage: elf_to_mem.py <objdump.exe> <firmware.elf> <firmware.mem>", file=sys.stderr, )   
        return 1

    objdump_exe = sys.argv[1]
    elf_file = Path(sys.argv[2])
    mem_file = Path(sys.argv[3])

    if not elf_file.exists():
        print(f"ERROR: ELF file not found: {elf_file}", file=sys.stderr)
        return 1

    # Generate disassembly
    try:
        result = subprocess.run(
            # ["riscv-none-elf-objdump", "-d", str(elf_file)],
            [objdump_exe, "-d", str(elf_file)],
            capture_output=True,
            text=True,
            check=True,
        )
    except Exception as e:
        print(f"ERROR: Failed to run objdump: {e}", file=sys.stderr)
        return 1

    disassembly = result.stdout

    # Save listing next to mem file
    lst_file = mem_file.with_suffix(".lst")
    lst_file.write_text(disassembly)

    # Match instruction words:
    #
    # 0:   00a00093    li ra,10
    # 4:   01400113    li sp,20
    #
    pattern = re.compile(
        r'^\s*[0-9a-fA-F]+:\s+([0-9a-fA-F]{8})\b',
        re.MULTILINE
    )

    instructions = pattern.findall(disassembly)

    if not instructions:
        print(
            "ERROR: No instructions found in objdump output",
            file=sys.stderr,
        )
        return 1

    with open(mem_file, "w") as f:
        for inst in instructions:
            f.write(inst.lower() + "\n")

    print(f"[FW] Generated {mem_file}")
    print(f"[FW] Generated {lst_file}")
    print(f"[FW] Instructions: {len(instructions)}")

    return 0


if __name__ == "__main__":
    sys.exit(main())