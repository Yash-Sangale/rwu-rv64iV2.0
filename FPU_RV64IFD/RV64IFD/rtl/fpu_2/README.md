# Building a Modular IEEE-754 Double Precision FPU in SystemVerilog

This repository contains the RTL (SystemVerilog) for an IEEE-754 Double Precision (64-bit) Floating-Point Unit. 

Instead of writing a monolithic "calculator" block that tries to do everything at once, this project was designed to mimic how real high-performance CPUs handle floating-point math. We focused heavily on decoupled logic, resource sharing, and preserving bit-level precision across module boundaries.

##  The Core Architecture: How It Actually Works

The biggest challenge in floating-point math isn't the addition itself, it's the formatting, the edge cases (like NaNs and Infinities), and the normalization. To handle this efficiently, the FPU is split into distinct stages connected by a multiplexer "highway."

### 1. The Brain: Look-Ahead Control & Classification (`fpu_ctrl` & `fpu_class`)
Before any math happens, the Control Unit looks at the instruction and the raw inputs. 
* It uses the `fpu_class` module to instantly figure out what kind of numbers we are dealing with (e.g., is it a Normal number, a Quiet NaN, or Infinity?).
* The "Fast Lane" Bypass: If the controller spots a NaN in the inputs, or if the instruction is just a classification check (`FCLASS`), it completely disables the math pipeline. It sets a `handle_special` flag, which tells the final output multiplexer to ignore the math blocks and instantly output a pre-defined result (like the Canonical NaN bit-pattern). This saves time and prevents invalid data from crashing the math units.

### 2. The Muscle: "Unpacked" Arithmetic (`fpu_add_sub`, `fpu_align`)
When standard math *is* required, the data flows into the execution units. 
* Alignment: For addition/subtraction, `fpu_align` compares exponents and shifts the smaller mantissa to the right so the decimal points line up.
* The 54-bit Secret: A major design choice here is that the adder does notoutput a standard 64-bit packed float. If it did, we would lose precision. Instead, `fpu_add_sub` outputs the raw sign, the exponent, and a 54-bit unpacked mantissa (52 bits of fraction + 1 hidden bit + 1 carry-out bit). We keep these extra bits alive so the next stage can use them.

### 3. The Highway: The Math Mux (`fpu_top`)
Because we plan to add Multipliers and Fused-Multiply-Add (FMA) blocks later, we don't want to wire the adder directly to the output. Instead, all execution units dump their raw, unpacked results into a central Multiplexer. The Control Unit acts as the traffic cop, selecting which math block's results get to move forward on the "common bus" based on the current opcode.

### 4. The Shared Utility: Normalization (`fpu_normalize`)
Normalizers are massive hardware blocks (they require large priority encoders and barrel shifters). If we put a normalizer inside the Adder, and another inside the Multiplier, we'd waste a massive amount of silicon. 
* By placing `fpu_normalize` after the Math Mux, all math blocks share a single normalizer. 
* It takes that raw 54-bit mantissa from the Math Mux, finds the first leading '1' (whether it's at bit 53 due to an overflow, or way down at bit 12 due to a massive subtraction cancellation), and shifts the bits left or right while adjusting the exponent to match.

### 5. The Final Output: The Bypass Mux
At the very end of `fpu_top`, a final decision is made. If the Control Unit triggered that `handle_special` flag back in Step 1, this Mux outputs the special NaN/Class result. Otherwise, it takes the cleanly normalized sign, exponent, and mantissa, packs them back into a standard IEEE 64-bit struct, and outputs the result.

---

##  Current Project Status

The foundational routing architecture and the Addition/Subtraction pipeline are completely functional.

* Routing & Control: `fpu_top.sv`, `fpu_ctrl.sv`, `fpu_class.sv` are fully integrated. The bypass logic successfully catches edge cases without touching the arithmetic datapath.
* Math Pipeline: `fpu_add_sub.sv`, `fpu_align.sv`, and `fpu_normalize.sv` are wired up and passing the full 54-bit precision through the shared Math Mux.
* Definitions: `fpu_pkg.sv` contains all standard IEEE-754 opcodes, rounding modes, and status flag definitions.

---

##  Next Steps

With the "highway" built, adding new features simply means plugging new blocks into the existing Mux structure.

1. Rounding (`fpu_rounding.sv`):
   * Currently, the normalizer truncates down to 52 bits. We need to implement the IEEE rounding modes (Round to Nearest Even, Round to Zero, etc.) by evaluating the Guard, Round, and Sticky bits.
   * This stage will also generate the standard IEEE exception flags (Inexact, Overflow, Underflow, Divide by Zero).
2. Expansion to Multiplication (`fpu_mul.sv` / `fpu_fma.sv`): 
   * Build the multiplier arrays. Because of the shared architecture, we only need to write the raw math logic; the existing `fpu_normalize` block will handle the post-processing automatically.
3. Advanced Math-Generated NaNs:
   * Update the Control Unit to detect things like $\infty - \infty$ during subtraction, which should generate a Quiet NaN on the fly.
4. Verification:
   * Develop a comprehensive SystemVerilog testbench suite to push edge cases (subnormals, massive cancellations, NaN propagation) through the pipeline.