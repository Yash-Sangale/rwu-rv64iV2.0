# riscv64_mcu — Simulation Toolchain

CMake + CTest infrastructure for SystemVerilog simulation, waveform capture, and FPGA synthesis.

---

## Prerequisites

Run `cmake --preset vivado` and check the tool status table printed at the end of configure. Each line shows `[OK]` or `[!!] NOT FOUND` with an install hint.

| Tool | Role | Required |
|---|---|---|
| Vivado / xsim | Primary simulation backend | Yes (for `SIM=vivado`) |
| Verilator 5+ | Open-source simulation backend, CI | Yes (for `SIM=verilator`) |
| GTKWave | Waveform viewer for Verilator VCD output | Optional |
| riscv64-unknown-elf-gcc | Firmware cross-compilation | Optional |
| Git, Python 3, Ninja | Infrastructure | Optional |

Auto-provision RISC-V GCC if not on PATH:

```sh
cmake --preset vivado -DAUTO_PROVISION_RISCV=ON
```

---

## Configure

| Preset | What it does |
|---|---|
| `vivado` | Vivado/xsim, no waveforms — default for Windows & Linux |
| `vivado-wave` | Same but opens xsim GUI with waveforms on each run |
| `verilator` | Verilator simulation, no waveforms |
| `verilator-wave` | Verilator + VCD dump, opens GTKWave if found |
| `ci-linux` | Verilator, 8 parallel jobs — for CI pipelines |

```sh
cmake --preset vivado        # configure once (creates build/)
cmake --preset verilator     # switch simulator; reconfigures build/
```

---

## Run tests

```sh
ctest --preset unit               # all unit tests, 4 jobs (Vivado)
ctest --preset unit-verilator     # same, via Verilator
ctest --preset ci                 # CI: Verilator, 8 jobs
ctest -R tb_alu                   # single test by name
ctest -L unit                     # filter by label
```

---

## Waveforms

**Vivado — xsim GUI:**

```sh
cmake --preset vivado-wave
ctest --preset wave -R tb_alu     # opens xsim GUI for tb_alu
```

**Verilator — VCD + GTKWave:**

```sh
cmake --preset verilator-wave
ctest --preset wave-verilator -R tb_alu   # writes .vcd, opens GTKWave
```

---

## Synthesis

Uncomment the `register_synth_run()` block in the root `CMakeLists.txt` and set your part number, then:

```sh
ctest --preset synth              # synth → place → route → bitstream
ctest --preset synth -R synth_top # specific run only
```

Outputs land in `build/synth/<name>/` — bitstream, timing report, utilisation report, power report.

---

## Adding a new module

**1. Register the RTL** — `rtl/mymodule/CMakeLists.txt`:

```cmake
register_rtl_module(
    NAME  mymodule
    FILES ${CMAKE_CURRENT_SOURCE_DIR}/mymodule.sv
)
```

**2. Register the testbench** — `tb/unit/mymodule/CMakeLists.txt`:

```cmake
register_tb(
    NAME        tb_mymodule
    TB          tb_mymodule.sv
    RTL_MODULES mymodule
    TIMEOUT     120           # optional, seconds (default: 120)
    WAVE        OFF           # optional, overrides global WAVE
)
```

**3. Wire into the root `CMakeLists.txt`:**

```cmake
add_subdirectory(rtl/mymodule)        # must come before tb/
add_subdirectory(tb/unit/mymodule)
```

---

## Testbench result contract

Every testbench must write a result file to the path received via the `+RESULT_FILE=<path>` plusarg. The file must contain exactly one of:

```
STATUS=PASS
STATUS=FAIL
STATUS=FAIL
REASON=short description here
```

CTest reads `[SIM] PASSED` / `[SIM] FAILED` from stdout to report pass/fail independently of exit code.

---

## Project layout

```
rtl/                  # synthesisable RTL only — no testbench code here
  pkg/                # shared SV packages, compiled first in every run
  alu/ fpu/ core/ memory/ …
tb/
  unit/               # one testbench per RTL leaf module
  integration/        # multi-module tests (future)
  system/             # full-chip tests (future)
constraints/          # XDC files for synthesis
sw/                   # firmware source (compiled with RISC-V GCC)
.dev/                 # build infrastructure
  cmake_modules/      # toolchain, rtl_module, tb_module, synth_module, targets
  scripts/
    vivado/           # sim_driver.cmake, synth_driver.cmake, wave.tcl
    verilator/        # sim_driver.cmake
    common/           # result_check.cmake (shared pass/fail logic)
  provision/          # fetch_riscv_gcc.cmake (auto-download)
build/                # all artefacts — never committed to git
```

---

## Build artefacts

| Path | Contents |
|---|---|
| `build/sim/<tb>/sim_full.log` | Full xvlog / xelab / xsim output |
| `build/sim/<tb>/<tb>_result.txt` | `STATUS=PASS` / `FAIL` written by testbench |
| `build/sim/<tb>/<tb>.wdb` | Vivado waveform database (`WAVE=ON` only) |
| `build/sim/<tb>/<tb>.vcd` | VCD dump for GTKWave (Verilator `WAVE=ON` only) |
| `build/synth/<name>/<top>.bit` | Vivado bitstream |
| `build/synth/<name>/timing.rpt` | Timing summary report |
| `build/synth/<name>/util.rpt` | Utilisation report |

---

## Toolchain internals (for contributors)

The `.dev/` tree follows a backend abstraction model. `targets.cmake` is the only file that knows which simulator is active — it picks the right driver script and passes it to CTest via `cmake -P`. Adding a new simulator means:

1. Add detection in `toolchain.cmake`
2. Create `scripts/<backend>/sim_driver.cmake`
3. Add one `elseif` branch in `targets.cmake`

Nothing else changes. The `register_rtl_module` / `register_tb` API is stable and backward compatible.

---

*Toolchain v2.0 · Windows & Linux · CMake 3.20+*
