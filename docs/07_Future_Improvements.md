# Document 7: Future Improvements & Performance Roadmap

**Date:** 2026-04-21 | **Version:** 1.0

---

## Table of Contents

1. [Critical Bug: Cache Pipeline Broken](#1-critical-bug-cache-pipeline-broken)
2. [O(1) Width Sweep Optimization](#2-o1-width-sweep-optimization)
3. [Linear Algebra: 20x Regression Fix](#3-linear-algebra-20x-regression-fix)
4. [SIMD Acceleration (f64)](#4-simd-acceleration-f64)
5. [Streaming Pipeline & Parallelization](#5-streaming-pipeline--parallelization)
6. [GPU Compute Backend](#6-gpu-compute-backend)
7. [Missing Features vs ngspice/HSPICE](#7-missing-features-vs-ngspicehspice)
8. [Implementation Waves](#8-implementation-waves)

---

## 1. Critical Bug: Cache Pipeline Broken

### The Problem

`patch_scale()` in `CompiledEvalCache` correctly patches affine models (I0, G) for W/L scaling changes, but the result is **immediately overwritten** by a full re-evaluation.

**Current flow for W change:**

```
1. CacheManager::mark_param_changed(dev, "w", 2.0)
2. Classify → ParamChange::Scaling { factor: 2.0 }
3. CompiledEvalCache::patch_scale(dev, 2.0)     ← patches I0, G correctly
4. DirtyTracker::mark_param_changed(dev)          ← marks device DIRTY
5. solve_cached() sees device dirty               ← ALWAYS full re-eval for dirty
6. Full BSIM4 evaluate_dc()                       ← OVERWRITES the patch from step 3
```

**Impact:** Affine scaling — the entire reason `patch_scale()` exists — is dead code. Every W/L sweep point pays full BSIM4 eval cost (~1000 FLOPs) instead of ~5 multiplies.

### The Fix

Add `ParamChange::LinearScaling` variant that patches affine model **without** marking device dirty:

```
1. CacheManager::mark_param_changed(dev, "w", 2.0)
2. Classify → ParamChange::LinearScaling { factor: 2.0 }
3. CompiledEvalCache::patch_scale(dev, 2.0)     ← patches I0, G
4. DirtyTracker: NOT marked dirty                ← device stays CLEAN
5. solve_cached() sees device clean              ← uses patched affine model
6. Woodbury rank-k update for Jacobian           ← incremental matrix update
```

### Files to Modify

| File | Change |
|------|--------|
| `crates/cache/src/manager.rs:151-175` | Add `LinearScaling` classification for W, M, area, scale |
| `crates/cache/src/manager.rs:195-205` | Skip `dirty_tracker.mark_param_changed()` for `LinearScaling` |
| `crates/cache/src/compiled_eval.rs:264-282` | Already correct — no change needed |
| `crates/solver/src/stamper.rs` | Wire Woodbury for Jacobian delta from patched conductances |

### Woodbury Integration (Currently Disconnected)

`WoodburyUpdate` struct exists in `crates/cache/src/woodbury.rs` with working Sherman-Morrison math. Comment says:

> "This is the *math* layer. Wiring it into `crates/solver/`'s sparse LU is deferred to the solver agent."

**What's needed:**
1. After `patch_scale()`, compute `ΔG` = change in device conductances at terminal positions
2. Form rank-k update: `J_new = J_old + U·V^T` where k = number of changed terminals (≤4 for BSIM4)
3. Call `WoodburyUpdate::solve()` with base solver closure for `J_old^{-1}`
4. Threshold: use Woodbury when `k ≤ √n`, refactorize when `k > √n`

**Cost comparison per W-sweep point (50-node test bench):**

| Operation | Current (broken) | Fixed (LinearScaling + Woodbury) |
|-----------|-----------------|----------------------------------|
| BSIM4 eval | ~3 µs (full) | **0** (skipped — affine patch) |
| Affine patch | ~0.1 µs (wasted) | ~0.1 µs (used) |
| LU refactor | ~10 µs | **0** (Woodbury instead) |
| Woodbury solve | 0 (not wired) | ~5 µs (rank-4 SM) |
| NR iterations | 5-8 (cold) | 1-2 (warm + accurate patch) |
| **Total** | ~27 µs | **~8 µs** |

**Speedup: ~3.4x per sweep point on top of existing cache benefits.**

---

## 2. O(1) Width Sweep Optimization

### BSIM4 W/L Dependency Analysis

Exhaustive audit of `crates/device/src/bsim4/eval.rs` reveals clear separation:

#### Linear-in-Weff (O(1) cacheable for W sweeps)

| Quantity | Formula | Scaling |
|----------|---------|---------|
| `Ids` (main current) | `beta0 = (Weff/Leff) * Coxe * mueff` | `∝ Weff` |
| `igidl`, `igisl` | `Agidl * Weff * f(V)` | `∝ Weff` |
| `cinv` (gate cap) | `Coxe * Weff * LeffCV` | `∝ Weff` |
| All `cgg`, `cgs`, `cgd` | Scale with `cinv` | `∝ Weff` |
| `gm`, `gds`, `gmbs` | Derivatives of Ids | `∝ Weff` |

**Exception — power law (still O(1)):**

| Quantity | Formula | Scaling |
|----------|---------|---------|
| `rds` (series R) | `Rdsw / (Weff * 1e6)^wr` | `∝ 1/Weff^wr` |
| `gds_eff` | `gds / (1 + gds*Rds)` | Nonlinear feedback via Rds |

The Rds feedback is a single scalar recompute — still O(1) per device.

#### Nonlinear-in-Leff (full eval required for L sweeps)

| Quantity | Nonlinearity Source |
|----------|-------------------|
| `Vth` | `exp(-dvt1 * Leff / lt0)` (short-channel roll-off) |
| `Vdsat` | `esatl = esat * Leff` in denominator (velocity saturation) |
| `Ids` denominator | `1 / (1 + Vdseff / esatl)` |
| `CLM` | `va_clm = pclm * esat * Leff` (channel-length modulation) |
| `DIBL` | `exp(-Dsub * Leff / lt0)` |

**No shortcut for L sweeps.** All voltage-dependent physics couples through Leff nonlinearly.

#### Temperature: Independent of W/L

`u0temp`, `vsattemp`, `vtm` are pre-computed from T/Tnom ratios. No geometry interaction. Temperature changes can be combined freely with W/L sweeps.

### Recommended Cache Strategy

```rust
/// Pre-compute once per (Leff, T, bias) tuple:
struct CachedLeffState {
    vth: f64,
    vgsteff: f64,
    mueff: f64,
    vdsat: f64,
    vdseff: f64,
    esatl: f64,
    va_clm: f64,
    clm: f64,
    ids_per_weff: f64,  // Ids / Weff (geometry-normalized)
    gm_per_weff: f64,
    gds_per_weff: f64,
    gmbs_per_weff: f64,
}

/// For each Weff in sweep — O(1):
#[inline]
fn scale_for_weff(cached: &CachedLeffState, weff: f64) -> Bsim4Output {
    let ids = cached.ids_per_weff * weff;
    let gm = cached.gm_per_weff * weff;
    let gds = cached.gds_per_weff * weff;
    // ... + Rds correction (single scalar op)
    Bsim4Output { ids, gm, gds, gmbs, igidl, igisl, caps }
}
```

### Sweep Ordering Optimization

For nested W/L sweeps, **L should be the outer loop**:

```
OUTER: L values (full BSIM4 eval each — unavoidable)
  INNER: W values (O(1) affine scaling — fast)
```

Current `.STEP` nesting order may be user-controlled. Could add auto-reordering heuristic:
- Detect W-only inner sweep → enable `LinearScaling` fast path
- Detect L-only inner sweep → no optimization possible
- Detect mixed → factor out W scaling from full eval

### Binning Parameters (Future Risk)

Currently **parsed but unused** in DC eval:

| Parameter | Effect if Enabled |
|-----------|-------------------|
| `dvt0w`, `dvt1w`, `dvt2w` | `exp(-scale/Weff)` in Vth → W sweep loses linearity |
| `voffl` | Additive `Voff + voffl/Leff` → L already nonlinear |
| `kt1l` | T×L coupling in mobility → breaks T/L orthogonality |

If binning params are enabled for foundry PDKs, W-sweep linearity breaks. Design should include a check: if any W-dependent Vth params are nonzero, fall back to full eval.

---

## 3. Linear Algebra: 20x Regression Fix

### The Problem

`rc_ladder_10k.sp` (10,000 nodes) is **20x slower** than ngspice. Primary target for Wave J.

### Root Cause: Simple AMD Ordering

`crates/linalg/src/amd.rs` (188 lines) uses a deliberately simple minimum-degree heuristic:
- `BTreeSet`-based adjacency lists
- O(n²) worst-case from adjacency updates during elimination
- Comment at line 11: *"For very large matrices (> 10k nodes) this should be replaced with a proper AMD or COLAMD implementation"*

For RC ladder (tridiagonal, ~3 nnz/row), this O(n²) dominates runtime at n=10K.

### BTF Status: Implemented & Working

`crates/linalg/src/btf.rs` (766 lines) — fully functional:
- Bipartite matching → maximum transversal
- Tarjan SCC on column dependency graph (iterative, no recursion)
- Outputs block structure for block-triangular solve

### KLU Status: Wrapped but Disabled

`crates/linalg/src/klu.rs` (511 lines) — complete FFI wrapper for SuiteSparse KLU:
- Behind `klu` Cargo feature flag
- Build system detects libklu.so via `SUITESPARSE_ROOT`, pkg-config, or Nix store
- Includes refactorize path for Newton iterations
- **Not enabled by default**

### Fix Roadmap

| Fix | Effort | Speedup (est.) | Risk |
|-----|--------|---------------|------|
| **Enable KLU by default** | 1 day | 10-15x on 10K nodes | Low (proven library) |
| **Replace AMD with COLAMD** | 1 week | 3-5x ordering time | Medium (new algorithm) |
| **BTF-aware parallel block factor** | 2 weeks | 1.3x additional | Medium (threading) |
| **Supernodal factorization** | 4 weeks | 1.5-2x cache reuse | High (restructure) |
| **Solve vector pooling** | 2 days | 5-10% | Low |

### Quick Win: Enable KLU

```toml
# Cargo.toml — change default features
[features]
default = ["klu"]  # Was: default = []
```

This alone should recover most of the 20x gap. ngspice uses KLU internally — same algorithm, same library. BigOSpice's wrapper is already complete.

### Medium-Term: Native COLAMD

Replace `amd.rs` with O(n·nnz) COLAMD:
- Mass elimination of degree-1/degree-2 vertices (common in circuit matrices)
- Supervariable detection (nodes with identical adjacency)
- Approximate minimum degree with aggressive absorption

This makes the built-in solver competitive with KLU for circuits up to ~50K nodes without external dependency.

### Allocation Overhead in Solve Path

`crates/linalg/src/sparse_lu.rs` allocates temporary vectors on every solve:
- `vec![0.0; n]` for forward solve workspace (line 451)
- `y`, `z` vectors in solve path (lines 40, 44, 52)

Fix: pre-allocate workspace in `SparseLuFactors` struct, reuse across Newton iterations.

---

## 4. SIMD Acceleration (f64)

### Current State

`crates/utility/src/simd.rs` has **f32-only** SIMD kernels (SSE2):
- `add_scaled_f32`, `mul_scalar_f32`, `add_f32`, `sum_f32`, `min_f32`, `max_f32`, `clamp_f32`, `lerp_f32`, `dot_f32`

**Problem:** Entire numerical core uses **f64**. SIMD utilities are unused by hot paths.

### Phase 1: f64 SIMD Kernels (HIGH IMPACT)

Add AVX-256 f64 kernels to `crates/utility/src/simd.rs`:

```rust
#[cfg(target_arch = "x86_64")]
pub fn axpy_f64(alpha: f64, x: &[f64], y: &mut [f64]) {
    use std::arch::x86_64::*;
    let a = unsafe { _mm256_set1_pd(alpha) };
    let chunks = y.len() / 4;
    for i in 0..chunks {
        unsafe {
            let xv = _mm256_loadu_pd(x.as_ptr().add(i * 4));
            let yv = _mm256_loadu_pd(y.as_ptr().add(i * 4));
            let result = _mm256_add_pd(yv, _mm256_mul_pd(a, xv));
            _mm256_storeu_pd(y.as_mut_ptr().add(i * 4), result);
        }
    }
    // Scalar tail
    for i in (chunks * 4)..y.len() {
        y[i] += alpha * x[i];
    }
}
```

Mirror all existing f32 functions for f64: `dot_f64`, `sum_f64`, `norm_inf_f64`, `scale_f64`, etc.

### Phase 2: Apply to Hot Paths

| Target | File | Current | SIMD Type | Est. Speedup |
|--------|------|---------|-----------|-------------|
| `axpy`, `dot`, `norm2`, `norm_inf`, `scale` | `linalg/dense_vec.rs:67-88` | Scalar f64 iterator | f64 AVX-256 | **3-4x** |
| Residual assembly (BE, Trap, BDF) | `analysis/companion.rs:202-360` | Iterator chains f64 | f64 AVX-256 | **3-4x** |
| Sparse matrix-vector product | `linalg/csc.rs:284-299` | Scalar loop f64 | f64 AVX-256 | **2-3x** |
| Forward/back substitution | `linalg/sparse_lu.rs:421-507` | Sparse scatter f64 | f64 gather/mask | **1.5-2x** |

### Phase 3: AVX-512 (Optional)

AVX-512 processes 8 f64 values per instruction (vs 4 for AVX-256). Benefits:
- Masked operations (useful for sparse scatter in triangular solves)
- Conflict detection for gather operations
- 2x throughput on supported hardware

**Recommendation:** Start with AVX-256 (universal on modern x86-64). Add AVX-512 behind `#[cfg(target_feature = "avx512f")]` for servers/workstations.

### Estimated Overall Impact

For transient analysis (where residual assembly + BLAS dominate):
- Phase 1+2: **1.5-2x overall speedup** (BLAS + residual assembly are ~40% of wall time)
- Phase 3: Additional **1.2-1.5x** on AVX-512 hardware

---

## 5. Streaming Pipeline & Parallelization

### Current Architecture: Batch-Then-Write

All analyses accumulate ALL results in memory before writing:

```
DC Sweep:  Vec<Vec<f64>>  — 100K points × 100 nodes = ~80 MB buffered
Transient: BOTH flat AND nested storage (2x memory waste)
AC:        Full frequency sweep materialized
```

### Problem: Double-Buffering in Transient

`crates/analysis/src/transient.rs:1052-1053`:
```rust
node_voltages_flat.extend_from_slice(&x[..num_nodes]);  // Flat buffer
node_voltages_nested.push(x[..num_nodes].to_vec());     // ALSO nested Vec<Vec>
```

**Fix:** Remove `node_voltages_nested` (legacy). Keep only flat buffer + stride-based access. Saves 50% transient memory.

### Problem: Circuit Clone Per Sweep Point

`crates/analysis/src/dc_sweep.rs:77`, `dc_op.rs:366`:
```rust
let mut ckt = circuit.clone();  // Full deep clone per point
ckt.set_device_param(...);       // Then mutate
```

**Fix:** Mutation + restore pattern. Or `Cow<Circuit>` for deferred copy.

### High-Impact: Outer Sweep Parallelization

Nested DC sweep outer loop is **embarrassingly parallel**:

```rust
// Current (sequential):
for &outer_val in &config.outer_values {
    let mut outer_ckt = circuit.clone();
    for &inner_val in &config.inner_values {
        // ... solve ...
    }
}

// Proposed (parallel outer):
use rayon::prelude::*;
let results: Vec<Vec<DcOpResult>> = config.outer_values
    .par_iter()
    .map(|&outer_val| {
        let mut outer_ckt = circuit.clone();
        // ... inner sweep (sequential, warm-start chain) ...
    })
    .collect();
```

**Speedup: 4-8x on 8+ threads** for nested W/L characterization (1000 W × 100 L).

Inner loop stays sequential (warm-start dependency chain). Only outer dimension parallelizes.

### Streaming Output

Decouple solver from output writer:

```
Solver Thread ──→ bounded channel ──→ Writer Thread
   (compute N)       (buffer 2-4)        (write N-2)
```

Hides I/O latency. Benefit: 10-15% for large ASCII output. Minimal benefit for binary rawfile.

### Priority Summary

| Optimization | Effort | Speedup | Memory |
|-------------|--------|---------|--------|
| **Outer sweep parallelization** | 1 week | 4-8x (nested DC) | +N×circuit_size |
| **Remove transient double-buffer** | 2 days | — | -50% transient |
| **Warm-start solution pooling** | 3 days | 5-10% | -10-20% |
| **Streaming output channel** | 1 week | 10-15% (I/O) | Minimal |
| **Circuit clone elimination** | 1 week | 5-10% | -5-10% |
| **Arena-based sweep results** | 3 days | 2-3% | -10-15% |

---

## 6. GPU Compute Backend

### Current State

**API:** wgpu (WebGPU) — Vulkan/Metal/DX12/OpenGL portable.

**What works:**
- BLAS-1 vector operations: `axpy`, `scale`, `dot`, `norm_inf` (GPU shaders in `blas.wgsl`)
- Memory pool with arena allocation
- `AlignedVec` for 64-byte cache-line alignment

**What's broken:**

#### GPU BSIM4 Evaluation: Shader Exists, Dispatch Missing

`bsim4_eval.wgsl` (389 lines) — complete BSIM4 DC evaluation shader:
- Vth with body effect, SCE, DIBL
- Mobility (MobMod 0), Vgsteff, Vdsat
- Ids with velocity saturation, CLM
- gm, gds, gmbs output

**But never called.** The dispatch in `bsim4_batch.rs:415-427`:

```rust
pub fn eval_bsim4_batch(input, backend: &dyn ComputeBackend) -> Result<...> {
    // Cannot safely downcast &dyn ComputeBackend to WgpuBackend without Any.
    eval_bsim4_batch_cpu(input)  // ← ALWAYS CPU
}
```

**Fix:** Replace trait-object dispatch with enum dispatch or `Any`-based downcast:

```rust
pub enum ComputeDispatch {
    Cpu(CpuBackend),
    Gpu(WgpuBackend),
}

impl ComputeDispatch {
    fn eval_bsim4_batch(&self, input: &Bsim4BatchInput) -> Result<Bsim4BatchOutput> {
        match self {
            Self::Cpu(b) => eval_bsim4_batch_cpu(input),
            Self::Gpu(b) => b.eval_bsim4_batch_gpu(input),
        }
    }
}
```

#### f32/f64 Precision Mismatch

- GPU shader: **f32** (hardware-native, fast)
- Solver: **f64** (required for Newton convergence)
- BLAS shaders: f64 emulated via 2×u32 bit-packing (`blas.wgsl:12`)

**Options:**
1. **Mixed precision:** GPU f32 device eval → CPU f64 Newton correction (iterative refinement)
2. **f64 extension:** Use `GL_EXT_shader_explicit_arithmetic_types_float64` if GPU supports
3. **f32-only circuits:** For characterization sweeps where 7-digit precision suffices

#### GPU BLAS Overhead

For typical Newton vectors (100-10K elements):
- GPU: ~2-3 µs per op (upload + kernel + readback)
- CPU: ~0.5 µs per op (L3 cache hit)

**GPU BLAS is 5-10x slower** at these sizes. Only viable for n > 50K.

**Fix:** Raise `min_gpu_size` threshold. Or batch multiple operations into single GPU dispatch.

### GPU Improvement Roadmap

| Fix | Effort | Impact | Priority |
|-----|--------|--------|----------|
| **Fix BSIM4 GPU dispatch** | 3 days | Enable GPU device eval | **HIGH** |
| **Enum-based compute dispatch** | 2 days | Clean architecture | **HIGH** |
| **Mixed-precision pipeline** | 2 weeks | f32 GPU eval + f64 NR correction | **HIGH** |
| **Batch sweep on GPU** | 3 weeks | N W/L points evaluated in parallel | **MEDIUM** |
| **Raise BLAS min_gpu_size** | 1 hour | Stop GPU overhead for small vectors | **HIGH** |
| **Solver GPU integration** | 4 weeks | GPU BLAS in Newton loop | **LOW** (overhead) |

### GPU Sweep Batching (Major Opportunity)

For W/L characterization, same circuit topology with different device params:

```
.STEP W 0.5u 10u 0.5u  → 20 W values

GPU batch: evaluate 20 BSIM4 instances simultaneously
- Same shader, same bias voltages
- Different W parameter per thread
- One kernel launch = all 20 variants
```

**Break-even:** ~100+ devices per evaluation. For circuits with 50+ transistors swept across 20+ W values, GPU batch wins.

**Implementation:** Extend `Bsim4BatchInput` to carry a parameter-variation dimension. Each GPU thread evaluates one (device, W) pair.

---

## 7. Missing Features vs ngspice/HSPICE

### Tier 1: Critical for Production (Wave III-IV)

| Feature | Status | Impact | Effort |
|---------|--------|--------|--------|
| **DC OP with pinned `.IC` nodes** | Broken — IC applied post-OP | Oscillators, charge pumps, SRAM all fail | 1 week |
| **Conditional `.LIB` (`.IF/.IFDEF`)** | Not implemented | Blocks foundry PDK integration | 2 weeks |
| **LTRA port current bug** | Wrong current in history | lossy_tline_long NRMSE=1.53e-1 | 2 days |
| **DC sweep warm-start bug** | Contamination in nested DC | mosfet_ids_vds NRMSE=1.67e-1 | 3 days |

### Tier 2: Feature Parity (Wave IV-V)

| Feature | What's Missing | Impact |
|---------|---------------|--------|
| **BSIMSOI** | SOI MOSFET model | Blocks 22nm FDSOI / 22FDX PDKs |
| **EKV** | Charge-based MOSFET | Ultra-low-power analog (IoT) |
| **PSP** | Surface-potential MOSFET | Some foundry PDKs (NXP, GF) |
| **Polynomial E/G/F/H** | `POLY(n)` controlled sources | Legacy netlists |
| **Voltage-dependent C** | VC1, VC2 coefficients | Varactor modeling |
| **XSPICE code models** | 100+ digital primitives | Digital library (RAM, ROM, counters) |

### Tier 3: Nice-to-Have (Wave V+)

| Feature | Notes |
|---------|-------|
| `.OPTIMIZE` backend | Parser exists, no optimizer |
| Reliability (`.ROL`) | Config parsed, not integrated |
| Interactive plotting | CLI-only by design |
| libsim shared API | CLI-only by design |
| Adjoint sensitivity | Forward FD works, adjoint more efficient for many params |
| Gear BDF-6 | BDF-5 sufficient for most circuits |

### BigOSpice Exclusive Advantages (Keep & Enhance)

| Feature | Status |
|---------|--------|
| Harmonic Balance (HB) | ✅ Single/two/N-tone, APFT |
| Periodic Steady-State (PSS) | ✅ Shooting method |
| Envelope Following | ✅ Modulated RF |
| S-Parameters | ✅ Native N-port, Touchstone output |
| 6-layer incremental cache | ✅ (needs fix — see §1) |
| Anderson acceleration | ✅ NR convergence aid |
| Verilator co-sim | ✅ Superior to ngspice XSPICE IPC |
| GPU compute (wgpu) | ⚠️ Needs dispatch fix — see §6 |
| Data-oriented SoA design | ✅ Cache-friendly, SIMD-ready |

### Test Category Status (2026-04-18)

| Category | Pass Rate | Blocking Issue |
|----------|-----------|---------------|
| adversarial | 100% (6/6) | — |
| basic/analyses/fourier/noise/sensitivity/xyce/devices/digital | 100% | — |
| quick | 100% (6/6) | — |
| tline | 88% (7/8) | LTRA port current |
| dc_sweep | 83% (5/6) | Warm-start contamination |
| bjt | 80% (12/15) | Parasitic RC stamping |
| mosfet | 55% (12/22) | Transient IC handling |
| analog | 19% (3/16) | Colpitts oscillator IC |
| power | 13% (1/8) | Charge pump / regulator IC |
| scaling | TIMEOUT | rc_ladder_10k (§3) |

---

## 8. Implementation Waves

### Wave III (Immediate — Correctness)

**Goal:** Fix blocking correctness bugs. Unblock oscillators, charge pumps, SRAM, regulators.

| Task | Effort | Unblocks |
|------|--------|----------|
| DC OP pinned-IC logic | 1 week | analog (16 tests), power (8), mosfet (10) |
| LTRA port current fix | 2 days | tline (1 test) |
| DC sweep warm-start fix | 3 days | dc_sweep (1 test) |
| BJT parasitic RC stamping | 3 days | bjt (3 tests) |

**Expected test pass rate after Wave III:** ~85-90% (up from ~70%).

### Wave J (Performance — Linear Algebra)

**Goal:** Fix 20x rc_ladder_10k regression. Make BigOSpice competitive at 10K+ nodes.

| Task | Effort | Impact |
|------|--------|--------|
| Enable KLU by default | 1 day | 10-15x on large circuits |
| Replace AMD with COLAMD | 1 week | 3-5x ordering for built-in solver |
| Solve vector pooling | 2 days | 5-10% NR iteration overhead |
| BTF-aware parallel block factor | 2 weeks | 1.3x additional |

### Wave K (Performance — Cache Fix + SIMD)

**Goal:** Fix cache pipeline. Add f64 SIMD. Achieve 10-50x W/L sweep speedup.

| Task | Effort | Impact |
|------|--------|--------|
| Fix cache pipeline (§1) | 3 days | 3.4x per W-sweep point |
| Wire Woodbury into solver | 1 week | Avoid LU refactor for rank-k changes |
| f64 SIMD kernels | 1 week | 3-4x dense BLAS ops |
| SIMD residual assembly | 3 days | 3-4x transient residual |
| SIMD sparse matvec | 3 days | 2-3x SpMV |

### Wave L (Performance — Parallelization + GPU)

**Goal:** Parallel sweeps. Working GPU pipeline. 4-8x multi-core speedup.

| Task | Effort | Impact |
|------|--------|--------|
| Outer sweep parallelization (Rayon) | 1 week | 4-8x nested DC |
| Remove transient double-buffer | 2 days | 50% memory savings |
| Fix GPU BSIM4 dispatch | 3 days | Enable GPU device eval |
| Enum-based compute dispatch | 2 days | Clean GPU/CPU routing |
| Mixed-precision GPU pipeline | 2 weeks | f32 GPU + f64 NR correction |
| GPU sweep batching | 3 weeks | N W/L points in one kernel |
| Raise GPU BLAS threshold | 1 hour | Stop GPU overhead for small vectors |

### Wave M (Features — Model Coverage)

**Goal:** Feature parity with ngspice for production PDKs.

| Task | Effort | Impact |
|------|--------|--------|
| Conditional `.LIB` (`.IF/.IFDEF`) | 2 weeks | Foundry PDK integration |
| BSIMSOI model | 4-6 weeks | SOI process support |
| EKV model | 2-3 weeks | Ultra-low-power analog |
| PSP model | 3-4 weeks | Selected foundry PDKs |
| Polynomial E/G/F/H | 1 week | Legacy netlist compat |
| Voltage-dependent C | 3 days | Varactor modeling |

---

## Appendix A: File Reference

### Cache System
| File | Purpose |
|------|---------|
| `crates/cache/src/compiled_eval.rs` | Affine model storage + `patch_scale()` |
| `crates/cache/src/manager.rs` | Parameter change classification + dispatch |
| `crates/cache/src/dirty_tracker.rs` | BitVec device/node dirty propagation |
| `crates/cache/src/woodbury.rs` | Sherman-Morrison-Woodbury math (disconnected) |
| `crates/cache/src/op_cache.rs` | Operating point warm-start cache |

### Linear Algebra
| File | Purpose |
|------|---------|
| `crates/linalg/src/sparse_lu.rs` | Gilbert-Peierls left-looking LU |
| `crates/linalg/src/amd.rs` | Simple AMD ordering (bottleneck) |
| `crates/linalg/src/btf.rs` | Block Triangular Form decomposition |
| `crates/linalg/src/klu.rs` | SuiteSparse KLU FFI wrapper |
| `crates/linalg/src/csc.rs` | CSC matrix + SpMV |
| `crates/linalg/src/dense_vec.rs` | Dense vector BLAS (no SIMD) |

### Compute
| File | Purpose |
|------|---------|
| `crates/compute/src/gpu_backend.rs` | wgpu GPU backend (BLAS only) |
| `crates/compute/src/bsim4_batch.rs` | Batch BSIM4 eval (CPU-only dispatch) |
| `crates/compute/src/parallel.rs` | Rayon parallel wrappers |
| `crates/compute/src/memory_pool.rs` | Arena allocator for hot path |
| `crates/compute/src/aligned_vec.rs` | 64-byte aligned vectors |
| `crates/utility/src/simd.rs` | f32-only SIMD kernels |

### Analysis
| File | Purpose |
|------|---------|
| `crates/analysis/src/dc_sweep.rs` | DC sweep (batch-then-write) |
| `crates/analysis/src/transient.rs` | Transient (double-buffered) |
| `crates/analysis/src/companion.rs` | Residual assembly (SIMD target) |
| `crates/analysis/src/sweep.rs` | Parameter sweep wrapper |

### Device
| File | Purpose |
|------|---------|
| `crates/device/src/bsim4/eval.rs` | BSIM4 DC evaluation (W/L analysis target) |
| `crates/device/src/bsim4/params.rs` | BSIM4 model parameters (binning) |
| `crates/device/src/bsim4/instance.rs` | BSIM4 instance (Leff/Weff computation) |
| `crates/device/src/bsim4/setup.rs` | Geometry extraction |

---

## Appendix B: Performance Projection

### Current Baseline (Wave I, 2026-04-07)

- Geomean **2.5x faster** than ngspice on 7/8 corpus items
- `rc_ladder_10k.sp`: **20x slower** (linalg bottleneck)

### After Wave J (Linear Algebra)

- rc_ladder_10k: **20x slower → 1.5-2x faster** (KLU + COLAMD)
- Geomean: **2.5x → 3-4x faster** (large circuits benefit most)

### After Wave K (Cache Fix + SIMD)

- W/L sweeps: **3.4x additional** from cache pipeline fix
- Transient: **1.5-2x additional** from f64 SIMD
- Geomean: **4-6x faster** overall

### After Wave L (Parallelization + GPU)

- Nested DC sweeps: **4-8x additional** from Rayon outer parallelization
- GPU device eval: **2-4x additional** for 100+ device circuits
- W/L characterization (100K points): **50-100x faster** than ngspice (cache + parallel + SIMD)

### Target: Wave M Completion

- **10-50x faster** than ngspice across full benchmark corpus
- **Feature parity** for production PDK support
- **GPU-accelerated** characterization workflows
