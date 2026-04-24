# Document 8: Integer vs Floating-Point — Would Removing All Floats Help?

**Date:** 2026-04-21 | **Version:** 1.0

---

## Executive Summary

**No. Converting BigOSpice to fixed-point integer arithmetic would make it slower, less accurate, and harder to maintain.** The premise that integers are faster than floats is outdated — it applied to CPUs without hardware FPUs (pre-2000 embedded, DSPs). On modern x86-64 and ARM, floating-point is **as fast or faster** than integer for multiply, divide, and FMA. SIMD makes the gap worse: there is no SIMD integer divide instruction, and Intel's SIMD integer multiply is 3x slower than SIMD float multiply.

---

## 1. The Premise: "Integers Are Faster Than Floats"

### Where This Was True

- **Embedded MCUs without FPU** (ARM Cortex-M0, 8-bit AVR): Float is software-emulated (~100 cycles per FMUL). Fixed-point is 10-50x faster.
- **Early DSPs** (TI C54x, SHARC): 16-bit fixed-point multiply in 1 cycle, no float unit.
- **1990s x86** (i486, Pentium): x87 FPU was slow, shared, and had pipeline stalls.

### Where This Is False (Modern Hardware)

Every modern x86-64 and ARM A-profile CPU has a **fully pipelined, multi-port floating-point unit** that matches or exceeds integer throughput for all operations except simple addition.

---

## 2. Hard Numbers: Instruction Latency & Throughput

### AMD Zen 4 (Desktop/Server, 2022+)

| Operation | Integer (i64) | Float (f64) | Winner |
|-----------|--------------|-------------|--------|
| **ADD** | 1 cycle, 6/cycle | 3 cycles, 2/cycle | Integer (latency) |
| **MUL** | 3 cycles, 1/cycle | 3 cycles, 2/cycle | **Float** (throughput) |
| **DIV** | 9-18 cycles, 0.14/cycle | 13 cycles, 0.08/cycle | Comparable |
| **FMA (a×b+c)** | Does not exist | 4 cycles, 2/cycle | **Float only** |

### Intel Golden Cove / Alder Lake P-core (2021+)

| Operation | Integer (i64) | Float (f64) | Winner |
|-----------|--------------|-------------|--------|
| **ADD** | 1 cycle, 5/cycle | 2 cycles, 2/cycle | Integer (latency) |
| **MUL** | 3 cycles, 1/cycle | 4 cycles, 2/cycle | **Float** (throughput) |
| **DIV** | 14-18 cycles, 0.1/cycle | 13 cycles, 0.25/cycle | **Float** (both) |
| **FMA (a×b+c)** | Does not exist | 4 cycles, 2/cycle | **Float only** |

### Apple M1 Firestorm (ARM, 2020+)

| Operation | Integer (i64) | Float (f64) | Winner |
|-----------|--------------|-------------|--------|
| **ADD** | 1 cycle, 6/cycle | 2-3 cycles, 4/cycle | Integer (latency) |
| **MUL** | 3 cycles, 2/cycle | 2-4 cycles, **4/cycle** | **Float** (2x throughput) |
| **DIV** | 7+ cycles, 0.5/cycle | variable, 1/cycle | **Float** (throughput) |
| **FMA** | 3 cycles, 1/cycle (MADD) | ~4 cycles, **4/cycle** | **Float** (4x throughput) |

**Key takeaway:** Integer ADD wins on latency (1 vs 2-3 cycles). But MUL, DIV, and FMA — the operations that dominate scientific computing — are **faster in floating-point** on every modern architecture.

Apple M1 has **4 FP execution units** vs **2 integer multiply units**. Float throughput is literally 2x higher.

---

## 3. SIMD: The Nail in the Coffin

### Elements Per Register (Same for Int and Float)

| Type | 128-bit (SSE2/NEON) | 256-bit (AVX2) | 512-bit (AVX-512) |
|------|---------------------|----------------|-------------------|
| i32 / f32 | 4 | 8 | 16 |
| i64 / f64 | 2 | 4 | 8 |

Same element count. Register width is just bits. No advantage either way.

### SIMD Operation Comparison (AVX2 256-bit, Zen 4)

| Operation | Integer (i32) | Float (f32) | Winner |
|-----------|--------------|-------------|--------|
| **ADD** | VPADDD: 1c lat | VADDPS: 3c lat | Integer |
| **MUL** | VPMULLD: 3c lat (AMD) / **10c lat (Intel!)** | VMULPS: 3-4c lat | **Float** (esp. Intel) |
| **FMA** | **DOES NOT EXIST** | VFMADD: 4c lat, 0.5 CPI | **Float only** |
| **DIV** | **DOES NOT EXIST** | VDIVPS: ~11-13c lat | **Float only** |

### Three Showstoppers

#### 1. No SIMD Integer Divide

There is **no SIMD integer divide instruction** in SSE2, AVX2, AVX-512, or NEON. Period. Not on any architecture. Not on any CPU ever made.

To divide 8 integers in an AVX2 register, you must:
- Extract each element to scalar
- Execute scalar IDIV (9-18 cycles each, NOT pipelined)
- Pack results back

**Cost: ~80-144 cycles for 8 integer divisions vs ~13 cycles for 8 float divisions with VDIVPS.**

Division appears in Newton-Raphson (J⁻¹ via LU solve), normalization, convergence checks, and every device model evaluation. This alone makes fixed-point SIMD 6-10x slower for division-heavy code.

#### 2. Intel SIMD Integer Multiply is 3x Slower

`VPMULLD` (packed 32-bit integer multiply) on Intel Golden Cove:
- **10-cycle latency** (same as CPUs from 2013)
- Intel's integer SIMD multiplier is microcoded, not fully pipelined

`VMULPS` (packed 32-bit float multiply) on the same CPU:
- **4-cycle latency**, fully pipelined

On the most common server CPUs (Intel Xeon), integer SIMD multiply is **2.5x slower** than float SIMD multiply. AMD Zen 4 is better (3 cycles for both), but you lose portability.

#### 3. No Integer FMA

Fused Multiply-Add (`a × b + c`) is the workhorse of linear algebra. Float FMA:
- Single instruction: 4 cycles, 2/cycle throughput
- Computes `a*b+c` with a single rounding (more accurate than separate MUL+ADD)

Integer equivalent requires:
- MUL: 3 cycles (produces i128 result for i64 × i64)
- Shift right by scale factor: 1 cycle
- ADD: 1 cycle
- Overflow check: 1-2 cycles
- **Total: 6-7 cycles, 1/cycle throughput**

Float FMA is **2x faster** per operation and **4x higher throughput** on Apple M1.

---

## 4. Fixed-Point Arithmetic Costs

### Multiply: i64 × i64 → i128

On scalar x86-64, `MUL r64` produces 128-bit result in RDX:RAX natively (3 cycles). But then:

```
MUL r64          ; 3 cycles — get 128-bit product
SHRD rax, rdx, K ; 1 cycle — shift right by scale factor K
JO overflow       ; 1 cycle — check overflow flag
; Total: 5 cycles per fixed-point multiply
```

vs `MULSD xmm, xmm`: 3-4 cycles. **Fixed-point multiply is 25-67% slower.**

In SIMD, it's catastrophic. There is no `i64 × i64 → i128` SIMD instruction. You must synthesize from four 32×32→64 multiplies:

```
; To multiply two vectors of 4 × i64 values with 128-bit intermediate:
VPMULUDQ  → low 64 bits of 32×32 products (4 ops)
VPSRLQ    → shift high halves
VPMULUDQ  → cross products
VPADDQ    → accumulate
VPSRLQ    → final shift
; Total: ~12 instructions, ~15-20 cycles for 4 elements
```

vs `VMULPD ymm, ymm, ymm`: 1 instruction, 3-4 cycles for 4 elements. **Fixed-point SIMD multiply is 4-5x slower.**

### Division: No Hardware Support

Fixed-point division options:
1. **Scalar IDIV**: 9-18 cycles, not vectorizable → 6-10x slower than float SIMD
2. **Newton-Raphson integer reciprocal**: 4-6 integer multiplies per division → ~20-30 cycles
3. **Use the float divider anyway** (convert int→float, divide, convert back): ~15 cycles with precision loss

### Overflow Detection

Every fixed-point ADD/SUB needs overflow checking. In scalar code: test overflow flag (`JO`, 1 cycle). In SIMD:

**There are no saturating 32-bit or 64-bit integer add instructions in AVX2/AVX-512.** Only 8-bit and 16-bit saturating adds exist (`VPADDSB`, `VPADDSSW`).

For 64-bit SIMD, overflow detection requires:
```
VPADDQ   ymm0, ymm1, ymm2   ; add
VPXOR    ymm3, ymm1, ymm2   ; check if signs differ (no overflow possible)
VPXOR    ymm4, ymm0, ymm1   ; check if result sign differs from input
VPANDN   ymm3, ymm3, ymm4   ; overflow = same-sign inputs, different-sign result
VPSRLQ   ymm3, ymm3, 63     ; extract sign bit
; 4 extra instructions per addition
```

**Fixed-point SIMD addition costs 5 instructions vs 1 for float.** And float overflow produces `±Inf` (safe, detectable) while integer overflow produces garbage (silent corruption).

---

## 5. Dynamic Range: Why i64 Cannot Cover SPICE

### BigOSpice Numerical Ranges (Audited from Source)

| Property | Minimum Value | Maximum Value | Orders of Magnitude |
|----------|-------------- |---------------|-------------------|
| Conductance (MNA matrix) | 1e-12 S | 1e6 S | **18** |
| Current (Ids) | 1e-15 A | 0.1 A | **14** |
| Voltage | 1e-10 V | 50 V | **11** |
| Capacitance | 1e-18 F | 1e-3 F | **15** |
| Charge tolerance | 1e-14 C | — | — |
| Pivot check threshold | 1e-30 | — | — |
| Physical constants | 1e-23 (Boltzmann) | 1e12 (1/ε₀) | **35** |

### i64 Range Analysis

`i64` range: -9.2×10¹⁸ to +9.2×10¹⁸ → **~18.96 decimal digits total**.

These digits must be split between **range** (orders of magnitude covered) and **precision** (significant digits at each scale).

**Scenario: Cover conductance range (1e-12 to 1e6)**

If scale factor places 1 LSB = 1e-12:
- Maximum representable: 9.2e18 × 1e-12 = 9.2e6 ✓ (barely covers 1e6)
- Precision at 1e6: 9.2e18 / 1e18 = 9.2 → **less than 1 significant digit**
- Precision at 1e-12: 18 significant digits ✓

You have **18 digits at the bottom and ~1 digit at the top**. Newton-Raphson needs at least 3-4 significant digits in every Jacobian entry to converge. This is fatal.

**Scenario: Use i128 (38 decimal digits)**

Covers range + precision, but:
- No native CPU support for i128 arithmetic (synthesized from 2× i64 ops)
- No SIMD support whatsoever
- Every operation costs 2-4x a single i64 operation
- **Slower than f64 by 2-4x with no upside**

### f64 Range Analysis

`f64`: 53-bit mantissa (15-16 significant digits) × 11-bit exponent (10^±308).

- At 1e-12: 15-16 significant digits ✓
- At 1e6: 15-16 significant digits ✓
- At 1e-30 (pivot check): 15-16 significant digits ✓
- At 1e-23 (Boltzmann): 15-16 significant digits ✓

**f64 gives 15-16 digits of precision at EVERY scale.** This is exactly what SPICE needs.

### The Jacobian Matrix Problem

A single row of the MNA Jacobian for a MOSFET node might contain:

```
[ 1e-15 (parasitic C)  |  1e-3 (gm)  |  -1e-3 (gm)  |  1e-6 (gds) ]
```

Ratio of largest to smallest entry: 1e-3 / 1e-15 = **1e12**. This is the local condition number.

With fixed-point scaled for the 1e-3 entry (say, 1 LSB = 1e-18):
- 1e-3 → 1e15 counts (fits in i64) ✓
- 1e-15 → 1e3 counts → **only 3 significant digits**
- Partial pivoting compares these values — with 3 digits of precision, pivot selection can be catastrophically wrong

With f64:
- 1e-3 → 15 significant digits ✓
- 1e-15 → 15 significant digits ✓
- Correct pivot selection guaranteed

---

## 6. Where Fixed-Point Fails for SPICE Physics

### Newton-Raphson Convergence

BigOSpice convergence criterion (`crates/solver/src/convergence.rs`):

```
|Δx_i| < abstol + reltol × |x_i|
       < 1e-12 + 1e-3 × |x_i|
```

For sub-threshold operation (`x_i` = 1e-14 A):
- Required precision: detect `Δx < 1e-12` on a value of `1e-14`
- Needs **2+ digits of precision at the 1e-14 scale**
- Fixed-point scaled for milliamp range → zero precision at femtoamp range

For strong inversion (`x_i` = 1e-3 A):
- Required precision: detect `Δx < 1e-6` on a value of `1e-3`
- Needs **3+ digits of precision at the 1e-6 scale**
- Both float and fixed-point handle this fine

**The problem is sub-threshold.** Fixed-point forces a tradeoff: either you have precision at the bottom (and overflow at the top) or range at the top (and lose precision at the bottom). Float handles both simultaneously.

### BSIM4 Model Evaluation

Internal BSIM4 computations include:

```rust
// Subthreshold smoothing (eval.rs ~line 163)
let vgsteff = vtm * ln(1 + exp((vgs - vth) / vtm));
// Where vtm = kT/q ≈ 0.026 V at room temperature
// exp() argument ranges from -40 to +40
// Result ranges from 1e-17 to 1e17
```

The `exp()` function:
- **Float**: Single instruction (`VEXPSD` on AVX-512, or library call ~20 cycles)
- **Fixed-point**: Taylor series or lookup table. For 15-digit accuracy over [-40, 40] range: ~50-100 integer operations, overflow risk at every step

```rust
// Gate-induced drain leakage (eval.rs ~line 318)
let igidl = agidl * weff * (vov / 3e-9) * exp(-3.0 * toxe * bgidl / vov);
// Involves: multiply (4×), divide (2×), exp (1×)
// Result range: 1e-20 to 1e-6 A
```

Every transcendental function (exp, ln, sqrt, pow) in BSIM4 would need a fixed-point implementation. These are slower and less accurate than IEEE 754 hardware implementations.

### Sparse LU Factorization

Pivot tolerance in `crates/linalg/src/sparse_lu.rs`:

```rust
if best_val.abs() < 1e-30 {
    return Err(SingularMatrix);
}
```

1e-30 is **below the range of i64 fixed-point** at any useful scale factor. This singularity detection would simply stop working.

During factorization, fill-in creates new matrix entries that are products and sums of existing entries. The dynamic range of intermediate values can exceed the input range by several orders of magnitude. Float handles this transparently; fixed-point would overflow.

### Charge Conservation in Transient

```
Q = C × V
dQ/dt = I
```

For C = 1e-15 F (1 fF), V = 1 V → Q = 1e-15 C.
Charge tolerance: `chgtol = 1e-14 C`.

Over 1000 timesteps, accumulated charge error must stay below 1e-14 C. Each timestep computes `Q_new = Q_old + I × Δt`, where:
- I might be 1e-6 A
- Δt might be 1e-9 s
- I × Δt = 1e-15 C (same order as Q itself)

This requires **cancellation-free summation** at the 1e-15 scale while Q accumulates to 1e-12 or larger. f64 handles this with 15 digits of relative precision. Fixed-point would need the scale factor set for the final Q value, leaving insufficient precision for the increments.

---

## 7. Industry Direction: MORE Precision, Not Less

### CircuitLab: Double-Double (2× f64 = ~32 digits)

CircuitLab implemented double-double arithmetic for their SPICE solver. Result: **20% faster overall** because convergence failures in switching circuits were eliminated. Fewer failed Newton iterations, fewer timestep reductions, fewer restarts. The precision investment paid for itself in reduced iteration count.

### SIMetrix: Quad Precision (f128 = 34 digits)

SIMetrix offers quad-precision mode for the hardest circuits (oscillators, PLLs, sigma-delta modulators). Same rationale: more precision → fewer convergence failures → faster wall-clock time.

### Penn (2009): Single-Precision BSIM4 Study

Research at University of Pennsylvania benchmarked f32 BSIM4 model evaluation with f64 matrix solve (mixed precision). Result: **required more Newton-Raphson iterations** to converge. The f32 model evaluation introduced noise into the Jacobian, degrading convergence rate.

**The literature unanimously shows: reducing precision makes SPICE slower, not faster.**

---

## 8. What About Specific Integer Tricks?

### Trick 1: Integer Indexing for Sparse Matrices

**Already done.** BigOSpice uses `u32` indices for CSC row/column pointers (`crates/linalg/src/csc.rs`). The values are f64, but structural operations (permutation, fill-in tracking, BTF decomposition) use integer arrays. This is standard practice.

### Trick 2: Fixed-Point for SIMD Batch Device Evaluation (f32 scaled to i16/i32)

Some GPU-oriented work (quantization in ML) converts f32 → i8/i16 for throughput. For BSIM4:
- **Input voltages**: 3 terminals × i16 (±32768 with 1mV resolution) — feasible
- **Output currents**: range 1e-15 to 0.1 — **not representable in i16 or i32**
- **Internal computation**: exp(), ln(), division — **no integer hardware support**

Verdict: Input quantization is possible but saves nothing (input is 3 values per device, trivial). Internal computation cannot be fixed-point.

### Trick 3: Posit/Unum (Alternative Float Formats)

Posit arithmetic (Gustafson, 2017) provides tapered precision — more digits near 1.0, fewer at extremes. Potentially useful for SPICE where most values cluster near typical operating points. But:
- No hardware support on any production CPU
- Software emulation is 10-100x slower than IEEE 754
- Research-only; no SPICE implementation exists

### Trick 4: Block Floating-Point (Shared Exponent)

Used in some DSP and ML accelerators. A block of values shares one exponent:
- Matrix column: all entries share one exponent, store mantissas as integers
- Reduces memory bandwidth (no per-element exponent)
- But SPICE matrix columns have 1e12 dynamic range within a single column → shared exponent doesn't work

---

## 9. Honest Assessment: When Would Integer Help?

### Case 1: Topology/Structural Operations

Already integer. Node indices, device indices, permutations, BitVec dirty tracking — all `u32`/`usize`. No float involved.

### Case 2: Hash Computation

Already integer. `FnvHasher` for topology cache uses integer operations exclusively.

### Case 3: Comparison-Heavy Code

Integer comparison is 1 cycle vs 3 cycles for float comparison (UCOMISD + branch). But BigOSpice's comparison-heavy code (convergence checks) is ~1% of total runtime. Saving 2 cycles per comparison is negligible.

### Case 4: If You Had a CPU Without an FPU

On ARM Cortex-M0+ (no FPU), fixed-point is 11x faster than software float. But BigOSpice targets x86-64 and ARM A-profile — both have full FPUs.

---

## 10. Conclusion

### Summary Table

| Claim | Reality |
|-------|---------|
| "Integer ADD is faster than float ADD" | **True** — 1 cycle vs 2-3 cycles latency. But ADD is <5% of SPICE runtime. |
| "Integer MUL is faster than float MUL" | **False** — Same latency, float has 2x throughput on M1. |
| "Integer DIV is faster than float DIV" | **False** — Float DIV is faster on all modern CPUs. |
| "Integer SIMD is same speed as float SIMD" | **False** — No SIMD integer DIV. Intel SIMD integer MUL is 3x slower. No integer FMA. |
| "Removing floats would speed up BigOSpice" | **False** — Would make it 2-5x slower due to SIMD penalties, overflow handling, and precision-induced convergence failures. |
| "i64 can cover SPICE dynamic range" | **False** — 18 digits total; SPICE needs 15 digits at EACH of 18+ orders of magnitude simultaneously. |

### The Real Optimization Path

Instead of replacing float with integer, the correct optimizations are:

1. **f64 SIMD** (AVX-256): 4 f64 ops per instruction → 3-4x speedup on dense BLAS (see doc 07 §4)
2. **Mixed precision**: f32 device eval + f64 solver with iterative refinement (see doc 07 §6)
3. **More precision where needed**: Double-double for ill-conditioned circuits (convergence speedup)
4. **Reduce operation count**: Cache pipeline fix (doc 07 §1), O(1) W-sweep (doc 07 §2)

The bottleneck in BigOSpice is **algorithm-level** (broken cache pipeline, simple AMD ordering, sequential sweeps), not **arithmetic-level**. Fixing the algorithms gives 10-50x speedup. Changing arithmetic type gives -2x to -5x (i.e., slowdown).

### Final Verdict

**Keep f64. Invest in SIMD f64 acceleration, cache pipeline fix, and algorithm improvements. Do not convert to fixed-point.**

The only integer optimization worth pursuing is ensuring structural/indexing operations (which are already integer) stay that way. The numerical core must remain IEEE 754 double-precision.

---

## Appendix: Sources

- **Agner Fog's Instruction Tables** — x86 latency/throughput data (agner.org/optimize)
- **uops.info** — Measured instruction performance (uops.info/table.html)
- **Chips and Cheese** — Golden Cove / Zen 4 microarchitecture analysis
- **Dougall Johnson** — Apple M1 Firestorm measurements (dougallj.github.io/applecpu)
- **ARM Cortex-A78 Software Optimization Guide** (developer.arm.com)
- **Penn FPL 2009** — Single-precision SPICE model evaluation study
- **CircuitLab** — Double-double arithmetic convergence improvement
- **SIMetrix** — Quad precision for hard convergence circuits
- **Analog Devices** — Fixed-point vs floating-point DSP performance
- **BEPUphysics** — Game engine fixed-point port (4x slower than float)
- **Sneller** — AVX-512 integer division synthesis (still uses FP units internally)
