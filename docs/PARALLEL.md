# Parallelism Architecture

ARPice exploits three parallelism levels: **SIMD** (within one core),
**CPU threads** (across cores), and **GPU** (cooperative kernels).  This
document describes each level, how they compose, what crosses which
boundary, and the roadmap toward a fully GPU-resident persistent context.

---

## 1. SIMD — vector-width parallelism

Every bulk f64 operation uses `@Vector(W, f64)` where
`W = std.simd.suggestVectorLength(f64) orelse 8`.  This adapts to the
widest native register at compile time (AVX-512: 8, AVX2: 4, NEON: 2).

Used in:
- `root.zeroSimd()` — zero a buffer
- `Circuit.combineGC()` — out = G + alpha * C
- `tran.integrator.stepBound()` — vectorized LTE divided-difference
- `mc.zig` — Bessel-corrected mean/std reduction
- `par.zig` — lane slab reduction (`addSimd`)
- All analysis hot paths (companion RHS, q-history rotation, etc.)

Convention: every SIMD loop has a scalar tail for non-W-aligned lengths.
No `@memset`, `@memcpy`, or `std.mem` in hot paths — SIMD loops only.

---

## 2. CPU threads — multi-core device evaluation

### 2.1 The lane model (`problem/par.zig`)

Device evaluation is the innermost hot loop of Newton iteration.
`ParEval` splits it across persistent worker threads:

```
Lane 0 (main thread): stamps directly into circuit planes (g_vals, c_vals, rhs, q_vec)
Lane 1..N:            stamps into private slab copies, then SIMD-reduced into lane 0's planes
```

**Determinism guarantee**: fixed partitioning + fixed lane-to-slab binding +
fixed ascending reduction order = bit-identical results at a given lane
count.  Serial (1 lane) differs only by reassociation of f64 addition.

**Work partitioning** (two passes):
1. Thread-unsafe batches (shared scratch) pinned whole to lane 0
2. Thread-safe batches cut greedily by weighted cost (weight = n_u^2 per
   instance) into contiguous ranges across lanes

**Scatter windows**: each lane precomputes the union of its tasks' scatter
bounds.  Zeroing and reduction touch only that window — cost tracks the
lane's working set, not the whole matrix.

**Activation**: `n_lanes >= 1` at circuit compilation; threshold
`default_min_instances = 1024` devices.  Workers are spawned once on
first eval and reused via epoch counter (spin-join, no mutex on hot path).
Fat stacks (512 MiB) per worker for runtime VA models with large frame
data.

### 2.2 What is NOT multi-threaded

| Component | Why serial |
|-----------|-----------|
| Newton iterations | Inherently sequential (x_{k+1} depends on x_k) |
| Transient time steps | Sequential (step n+1 needs step n's state) |
| LU factorization | Gilbert-Peierls is column-serial; GPU path exists for parallelism |
| MC/sweep outer loop | Each trial is independent but currently serial on CPU (GPU batching is the upgrade) |
| AC frequency sweep | Each point is independent but currently serial on CPU |
| GMRES inner loop | Modified Gram-Schmidt is sequential; classical GS + reorthogonalization would parallelize |

The design philosophy: device evaluation is the only CPU-parallel hot path
because it's the only part where parallelism is both safe (deterministic)
and profitable (thousands of independent instance evaluations).  Everything
else either can't parallelize (Newton) or should parallelize on GPU
(sweeps, MC).

---

## 3. GPU — cooperative kernels

### 3.1 Current architecture: one-solve-at-a-time

The GPU accelerates the innermost Newton solve via a cooperative megakernel.
The host packs a contiguous blob (`gpu_abi.zig`), uploads it, launches one
cooperative kernel, and reads back the result.

```
Host                         GPU
────                         ───
pack blob (CSC + devices)  → upload [0, off_ws)
launch arp_solve           → cooperative Newton/JFNK:
                               device eval (grid-stride, per-model batches)
                               JFNK: J·v via FD over device eval
                               convergence gates (grid-wide reductions)
                               thread-0 bookkeeping (Givens, back-subst)
                               software grid barrier between phases
readback [off_x, off_ws)   ← x + ResultHeader
```

**Four kernel entry points:**
- `arp_solve` — one Newton/JFNK solve (OP, DC sweep point)
- `arp_solve_batch` — N independent Newton lanes (MC, corners, temp, DC)
- `arp_tran` — chunked transient integration (up to 512 accepted steps
  per launch, integration state persists in device workspace between
  launches)
- `arp_freq_solve` — batch frequency-domain (G+jωC) solves (AC, noise,
  SP, STB) — standard launch, one block per frequency point

**GPU eligibility**: no circuit history devices, all batches have `gpu_pack`
hooks.  Failure falls through to CPU JFNK then CPU direct Newton.

**Converger dispatch order** (`converger.run`):
1. GPU whole-Newton (`gpu_hook.solve_newton`) — if `gpu_eligible` hook
2. CPU JFNK — default strategy (matrix-free, same algorithm as kernel)
3. CPU direct Newton — last resort (LU factorization)

JFNK is the default on all paths — GPU or not. It's faster for large
sparse systems where LU fill-in dominates, and it's the same algorithm
the megakernel runs, so CPU/GPU convergence is a superset.

### 3.2 GPU sparse LU infrastructure (`gpu_lu.zig`)

Level-scheduled factorization DAG ready for GPU kernel:
- Dependency detection from filled L/U patterns (look-up + look-left)
- Fixed-point iteration computes levels; within each level, columns are
  independent
- Per-level kernel mode classification: small_block (>16 cols),
  large_block (5-16), stream (<=4)
- Numeric factorization: left-looking hybrid with SIMD helpers
- **Status**: CPU simulation of the GPU flow; actual device kernel TBD

### 3.3 Build configuration

```sh
zig build -Dgpu=nvidia -Dgpu-nv-arch=sm_89   # CUDA path
zig build -Dgpu=amd -Dgpu-amd-arch=gfx1100    # HIP path
zig build -Dgpu=none                           # CPU-only (default)
```

The megakernel (`modules/devices/src/kernel.zig`) compiles to PTX/HSACO
from Zig via the NVPTX/AMDGPU LLVM backends.  Device model physics are
separate TUs linked via nvlink — the megakernel dispatches per-model
stubs at comptime.

---

## 4. PCIe traffic analysis

### Current (one-solve-at-a-time)

| When | Direction | Data | Size |
|------|-----------|------|------|
| Once per circuit | H→D | CSC pattern, device tapes, batch table | O(nnz + devices) |
| Per Newton solve | H→D | x vector, tolerance knobs | O(n) |
| Per Newton solve | D→H | x vector, convergence result | O(n) |
| Per transient chunk | H→D | x, breakpoints, probe list | O(n) |
| Per transient chunk | D→H | waveform points (up to 512 steps) | O(steps * probes) |

For an AC sweep with 500 frequency points: **1000 PCIe round-trips**
(one upload + one download per point).  For MC with 10000 trials:
**20000 round-trips**.  This is the bottleneck.

### Target (persistent GPU context)

| When | Direction | Data | Size |
|------|-----------|------|------|
| Once per circuit | H→D | Full blob (pattern + devices + workspace) | O(nnz + devices) |
| Per analysis | H→D | Sweep points / MC seeds / frequency list | O(N_points) |
| Per analysis | D→H | All results | O(N_points * probes) |

For AC sweep: **2 PCIe transfers total**.  For MC: **2 transfers total**.
Everything else stays on-device.

### Current implementation status (persistent context)

| Component | Status |
|-----------|--------|
| `GpuContext` (src/gpu_context.zig) | **Implemented** — persistent data residency, shared_uploaded flag |
| `arp_solve_batch` kernel | **Implemented** — `setupGLane` intra-lane barriers, multi-lane cooperative launch |
| `kernel_freq.zig` | **Implemented** — dense stacked-real LU, 1 block/point, standard launch |
| `solveBatch` host dispatch | **Implemented** — chunked multi-lane, serial fallback |
| `freqSolveBatch` host dispatch | **Implemented** — per-point scratch alloc, standard launch |
| `GpuHook` (7 fn ptrs) | **Implemented** — solve_newton, simulate_tran, solve_batch, freq_solve_batch, freq_solve_adjoint_batch, repack |
| MC/temp/DC batch wiring | **Implemented** — GPU single-solve per trial (per-lane payloads pending) |
| AC/noise/SP/STB batch wiring | **Implemented** — freq_solve_batch dispatch in run() |
| `Circuit.memoryFootprint()` | **Implemented** — byte-level breakdown for GPU budgeting |
| JFNK default strategy | **Implemented** — converger.run tries JFNK before direct Newton |

---

## 5. Architecture: persistent GPU context

### 5.1 The three pillars

Based on the literature (TinySPICE [DAC 2013], Tsinghua GPU-LU [IEEE TPDS
2015], Swirydowicz et al. [2023], PERKS [ICS 2023]):

**Pillar 1 — Data residency.**  Circuit matrix structure, device
parameters, and solver workspace live permanently in GPU global memory.
Symbolic factorization (KLU: BTF + AMD) done once on CPU, uploaded once.
All subsequent numerical refactorizations and solves are GPU-resident.

**Pillar 2 — Persistent kernel.**  The Newton iteration loop runs inside a
single long-lived cooperative kernel.  Device-wide barriers
(`grid_group.sync()` / PTX `bar.sync`) replace per-iteration kernel
launches.  Intermediates stay in registers/shared memory between
iterations — no L2 cache flush, no HBM round-trip.  PERKS showed 2.29x
from this alone.

**Pillar 3 — Inter-circuit parallelism.**  For MC/sweeps, map each
independent circuit instance to GPU threads (lanes).  Each lane runs its
own Newton ladder, independently converging or recording failure.  PCIe
traffic: parameters in, results out, nothing in between.

### 5.2 Analysis-level GPU dispatch

Each analysis type has a natural GPU parallelism axis:

| Analysis | Parallelism axis | Lanes | GPU pattern |
|----------|-----------------|-------|-------------|
| AC/noise/SP/STB | Frequency points | 100-10000 | Batch factor+solve at each omega |
| MC/corners/temp | Independent trials | 100-100000 | Full Newton per lane |
| DC sweep | Sweep points (chunked) | 10-1000 | Cold-start every Kth, warm-march gaps |
| Transient | Within-step (device eval, GMRES) | 1 circuit | Already persistent (arp_tran) |
| PSS shooting | Krylov vectors / FD columns | 30-100 | Period integrations in parallel |
| PAC/PXF/pnoise | Frequency x sideband x sample | 1000s | Embarrassingly parallel |
| FOUR/disto | Post-processing | small | CPU-only (cheap relative to main solve) |
| PZ | Eigensolves (MC ensembles) | per trial | Batched QR on small dense matrices |

### 5.3 Proposed interface

```zig
/// Persistent GPU context — circuit lives on-device.
pub const GpuContext = struct {
    /// One-time: upload blob, allocate workspace, symbolic setup.
    pub fn init(gpa, circuit, gpu_device) !GpuContext;

    /// Per-analysis batch dispatches.  All lanes run to completion
    /// in one kernel launch.  Results written to device-side output
    /// buffer, then bulk-downloaded.
    pub fn solveBatch(self, x_per_lane: [][]f64, opts_per_lane: []Options) ![]Result;
    pub fn freqSweepBatch(self, omegas: []f64, rhs: []f64, x_out: [][]f64) !void;
    pub fn tranChunk(self, x: []f64, probes, waveform, tran_opts) !SimResult;

    /// Tear down — free device memory.
    pub fn deinit(self) void;
};
```

The analysis `run()` functions would check for a `GpuContext` on `RunCtx`
and dispatch:

```zig
pub fn run(ctx: *const RunCtx, opts: Options) !Result {
    if (ctx.gpu_ctx) |gpu| {
        return runGpu(gpu, ctx, opts);  // batch dispatch, one PCIe round-trip
    }
    return runCpu(ctx, opts);           // current serial path
}
```

### 5.4 Implementation phases

**Phase A — Batched solve hook** (smallest change, biggest win):
Add `solve_batch` to `GpuHook`.  AC/noise/SP/STB/MC/corners/temp pack
all independent systems into one call.  The megakernel runs N lanes in
parallel.  Analysis code changes: replace frequency/trial loop with batch
call.  ~7 analyses benefit immediately.

**Phase B — Persistent kernel + data residency**:
Rewrite the megakernel as a persistent cooperative kernel.  The circuit
blob is uploaded once in `GpuContext.init()`.  Newton iterations use
`grid_group.sync()` barriers instead of kernel relaunches.  Intermediates
stay in shared memory / registers.  PCIe traffic drops to 2 transfers per
analysis.

**Phase C — Inter-circuit parallelism for MC**:
Each MC trial becomes a GPU lane with its own parameter set and Newton
state.  10000 trials run concurrently in one persistent kernel.  Non-
converged lanes record failure without blocking others.  Statistics
(mean, std, yield) computed on-device via grid-wide reductions.

**Phase D — Full analysis kernels**:
Analysis-specific kernels (AC sweep kernel, PSS shooting kernel) that
encode the full analysis algorithm on-device.  The host submits one
"run AC" command and receives the complete frequency response.  Most
complex; requires per-analysis kernel code.

### 5.5 Key constraints

**Memory**: a persistent context for a 10K-node circuit with 1M devices,
30 GMRES vectors, and 10000 MC lanes needs roughly:
- CSC pattern + values: ~40 MB
- Device tapes + params: ~100 MB (depends on model complexity)
- Solver workspace per lane: ~2 MB (dx, x_old, GMRES basis)
- 10000 lanes: ~20 GB solver workspace alone

This means MC at 10000 lanes needs a large-VRAM GPU (A100 40GB+).
Practical lane counts scale with available VRAM.

**Occupancy**: cooperative kernels are limited to simultaneously-active
blocks.  On an A100 (108 SMs, up to 32 blocks/SM): max ~3456 blocks.
This is enough for most analyses but constrains very large MC batches.

**Monotonic scheduling**: sync-free row-to-warp GPU LU depends on
hardware behavior (monotonic thread block scheduling) NOT guaranteed by
the CUDA spec.  Our `gpu_lu.zig` level-set approach is the safe path —
explicit dependency levels, no reliance on scheduling order.

**Zig+NVPTX**: all GPU primitives (cooperative launch, grid barriers,
atomics, shared memory) are PTX-level instructions accessible from Zig's
NVPTX backend.  No CUDA C++ runtime dependency.  The megakernel already
compiles from Zig.

---

## 6. Parallelism composition

The three levels compose without interference:

```
              ┌─────────────────────────────────────────────┐
              │              Analysis run()                 │
              │                                             │
              │   ┌─── GPU path ─────────────────────────┐  │
              │   │  Persistent kernel:                   │  │
              │   │    Lane 0..N (inter-circuit parallel) │  │
              │   │    Within each lane:                  │  │
              │   │      Device eval (grid-stride SIMD)   │  │
              │   │      JFNK (warp-level GMRES)          │  │
              │   │      Convergence (grid reductions)    │  │
              │   └───────────────────────────────────────┘  │
              │                     OR                       │
              │   ┌─── CPU path ─────────────────────────┐  │
              │   │  Newton iteration (serial):           │  │
              │   │    Device eval:                       │  │
              │   │      ParEval lanes 0..K (CPU threads) │  │
              │   │      Within each lane:                │  │
              │   │        SIMD f64 vector ops             │  │
              │   │    LU factor (serial, SIMD columns)   │  │
              │   │    Solve + convergence check           │  │
              │   └───────────────────────────────────────┘  │
              └─────────────────────────────────────────────┘
```

**CPU threads and GPU never run simultaneously** on the same circuit.  If
`gpu_active`, Newton goes through the GPU path; the CPU thread pool idles.
If GPU is unavailable or the hook fails, CPU threads handle device eval.

**SIMD is always active** — both CPU threads and GPU warps use vector
operations.  On CPU: explicit `@Vector(W, f64)`.  On GPU: implicit warp-
width SIMD (32 threads execute in lockstep).

---

## 7. Determinism

| Mechanism | Deterministic? | Condition |
|-----------|---------------|-----------|
| SIMD | Yes | Same platform, same binary |
| CPU threads (ParEval) | Yes | Same lane count (fixed partition + fixed reduce order) |
| GPU cooperative kernel | Yes | Same grid size, same circuit, same opts |
| MC RNG | Yes | Deterministic seed (default 42), counter-based substream per trial |

Cross-platform: results may differ by reassociation (f64 addition order
depends on vector width and lane count).  Same binary on same hardware
with same lane count: bit-identical.

---

## Sources

- TinySPICE: Han, Zhao, Feng (DAC 2013) — inter-circuit GPU parallelism
- Tsinghua GPU-LU: Chen et al. (IEEE TPDS 2015) — hybrid CPU-GPU sparse LU
- Swirydowicz et al. (2023) — GPU-resident refactorization, sync-free scheduling
- PERKS: Zhang et al. (ICS 2023) — persistent kernels, 2.29x from on-chip data reuse
- CUDA Graphs conditional nodes: NVIDIA Programming Guide (CUDA 12.4+)
- Device Graph Launch: NVIDIA developer blog — tail launch, self-relaunch
