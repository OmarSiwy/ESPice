# modules/solvers — Sparse & Dense Linear Algebra Engine

All solvers are comptime-generic over element type `T` (f64/f32), auto-vectorize
via `std.simd.suggestVectorLength(T)` (AVX-512/AVX2/SSE/NEON), and allocate
nothing in hot paths. Import through `root.zig`:

```zig
const solvers = @import("solvers");
```

## Module map

```
root.zig                 Module exports + shared types (BbdBlock, BbdInfo)
├── direct.zig           Sparse direct solver — dispatcher (Newton callers use this)
│   ├── sparse_lu.zig    Gilbert-Peierls left-looking sparse LU
│   ├── tridiag.zig      Thomas algorithm for tridiagonal patterns
│   ├── bbd.zig          Bordered block diagonal dense LU
│   └── order.zig        BTF (Tarjan SCC) + per-block AMD ordering
├── dense_lu.zig         SIMD-accelerated dense LU with partial pivoting
├── freq_solve.zig       Frequency-domain (G + jωC) solver for AC/noise
├── fft.zig              Radix-2 + Bluestein chirp-z FFT
├── gmres.zig            Right-preconditioned GMRES(m) Krylov solver
├── gpu_lu.zig           Level-set GPU sparse LU infrastructure
├── preconditioner.zig   Block-circulant / block-banded HB preconditioners
├── monodromy.zig        Matrix-free monodromy Φ·v products (PSS shooting)
├── lptv.zig             LPTV harmonic conversion-matrix solver (PAC/PXF)
├── converger.zig        Newton/JFNK convergence (generic over system type)
└── types.zig            Complex, LogSweep, Waveform measurement types
```

## Quick start — Newton loop (DC/transient)

The Newton caller uses `direct.Solver` — the dispatcher handles engine
selection (tridiag → BBD → sparse LU) and the refactor/factor pipeline
automatically.

```zig
const solvers = @import("solvers");
const Solver = solvers.direct.Solver;

// 1. Init once from frozen CSC pattern
var slv = try Solver.init(gpa, n, col_ptr, row_idx, bbd_info);
defer slv.deinit();

// 2. Factor (per Newton iteration — refactors when pattern unchanged)
try slv.factor(vals);

// 3. Solve  x = -A\rhs  (the Newton step)
slv.solveNeg(rhs, dx);

// 4. Adjoint solve  x = A'\rhs  (noise/sensitivity)
slv.solveT(rhs, x);
```

### Tuning knobs

```zig
var slv = try Solver.initParams(gpa, n, col_ptr, row_idx, bbd_info, .{
    .pivot_tol = 1e-3,              // threshold partial pivoting tolerance
    .refactor_growth_limit = 1e-12, // pivot-collapse monitor (0 = disable)
    .iter_refine_steps = 1,         // iterative refinement (0/1/2)
    .ordering = .amd,               // .amd or .natural
    .btf = true,                    // block triangular form before AMD
});
```

## Quick start — AC sweep

```zig
const FreqSolver = solvers.freq_solve.FreqSolver;

// Build from linearized circuit (one eval)
var fs = try FreqSolver.fromCircuit(gpa, ckt, x_op);
defer fs.deinit(gpa);

// Single-shot: factor + solve at one omega
try fs.solve(omega, rhs, x_out);

// Multi-RHS at same omega: factor once, solve many
try fs.setOmega(omega);
try fs.solveRhs(rhs1, x1);
try fs.solveRhs(rhs2, x2);

// Adjoint (noise/sensitivity)
try fs.solveRhsT(rhs, x_out);
```

## Quick start — dense LU

```zig
const dense_lu = solvers.dense_lu;

// Fused factor + solve (destroys A)
try dense_lu.factorizeSolve(n, a, b, x);

// Or negated RHS (Newton step)
try dense_lu.factorizeSolveNeg(n, a, b, x);

// Separate factor (reuse across multiple RHS)
try dense_lu.factorize(n, a, piv);
dense_lu.solveFactored(n, a, piv, b, x);
dense_lu.solveFactoredT(n, a, piv, b, x);  // transpose

// Stacked-real complex admittance: [G,-ωC; ωC,G]
dense_lu.buildComplexAdmittance(n, 2*n, g, c, omega, a_work);
```

## Quick start — FFT

```zig
const fft_mod = solvers.fft;

// Power-of-2 complex FFT (in-place, unnormalized)
fft_mod.fft(re, im);
fft_mod.ifft(re, im);

// Real-input FFT → N/2+1 complex bins
fft_mod.fftReal(signal, out_re, out_im);

// Arbitrary-length via Bluestein chirp-z
const m = fft_mod.bluesteinSize(n);
fft_mod.bluestein(re, im, scratch_re, scratch_im, chirp_re, chirp_im);
```

## Quick start — GMRES(m) Krylov

```zig
const Gmres = solvers.gmres.Gmres(f64);

// Allocate for n-dimensional system, restart every m iterations
var krylov = try Gmres.init(gpa, n, 30);
defer krylov.deinit(gpa);

// Solve A*x = b matrix-free
const result = krylov.solve(
    matvec_fn,       // fn(v, w, ctx) computes w = A*v
    ctx,             // opaque context for matvec
    precond_fn,      // optional right preconditioner (null = none)
    precond_ctx,
    b, x,            // RHS and solution (x = initial guess on entry)
    1e-10,           // relative tolerance
    10,              // max restarts
);
// result.converged, result.iterations, result.residual
```

## Quick start — monodromy (PSS shooting)

```zig
const Monodromy = solvers.monodromy.Monodromy(f64);

// Build from saved integration step records (one period)
var mono = try Monodromy.init(gpa, n, col_ptr, row_idx, step_records);
defer mono.deinit(gpa);

// Matrix-free products for Krylov shooting
mono.product(v, w);                   // w = Φ·v
mono.adjointProduct(v, z);            // z = Φᵀ·v
mono.shootingProduct(v, w);           // w = (Φ-I)·v
mono.adjointShootingProduct(v, z);    // z = (Φ-I)ᵀ·v
```

## Quick start — LPTV conversion-matrix solver

```zig
const LptvSolver = solvers.lptv.LptvSolver(f64);

var lptv = try LptvSolver.init(
    gpa, n, num_harmonics,
    col_ptr, row_idx,
    g_blocks, c_blocks,   // harmonic coefficient blocks [2M+1]
    omega0,
    .sparse_flat,          // .dense, .sparse_flat, or .matrix_free
);
defer lptv.deinit(gpa);

try lptv.setFreq(f);                // factor at analysis frequency
lptv.solveRhs(rhs, x);              // solve A(f)·X = B
lptv.solveRhsT(rhs, x);             // adjoint: A(f)ᴴ·Y = C
lptv.apply(v, w);                    // matrix-free: w = A(f)·v
```

## Quick start — structured preconditioner

```zig
const Preconditioner = solvers.preconditioner.Preconditioner(f64);

var prec = try Preconditioner.init(
    gpa, n, col_ptr, row_idx,
    num_harmonics, num_samples,
    g_samples, c_samples,   // period-sampled Jacobians
    omega0,
    .averaged_circulant,    // .dc_sample, .averaged_circulant, .block_banded
);
defer prec.deinit(gpa);

prec.apply(rhs);     // P⁻¹·rhs in-place
prec.applyT(rhs);    // P⁻ᵀ·rhs in-place
```

## Quick start — fill-reducing ordering

```zig
const order_mod = solvers.order;

// Workspace (no allocator needed — bump slab)
const ws_buf = try gpa.alloc(u32, order_mod.wsSize(n, nnz));
defer gpa.free(ws_buf);
var ws = order_mod.Ws.init(ws_buf);

// BTF + per-block AMD → column permutation q
try order_mod.order(n, col_ptr, row_idx, q, &ws);

// AMD only (no BTF)
try order_mod.amd(n, col_ptr, row_idx, q, &ws);
```

## Quick start — GPU sparse LU infrastructure

```zig
const GpuLu = solvers.gpu_lu.GpuLu(f64);

var gpu = try GpuLu.init(gpa, n, col_ptr, row_idx, q);
defer gpu.deinit(gpa);

// After symbolic factorization: compute level sets
gpu.levelize(up, ui);

// Inspect level structure
for (gpu.levels()) |level| {
    // level.start, level.count, level.mode (.small_block/.large_block/.stream)
}
```

## Architecture

All solvers follow these principles:

- **Zero allocation in hot paths.** All memory from `init`; `factor`/`solve`
  touch only pre-allocated workspace.
- **SIMD everywhere.** Every bulk operation uses `@Vector(W, T)` with
  `W = std.simd.suggestVectorLength(T)` — auto-scales to the widest native
  register (AVX-512: 8×f64, AVX2: 4×f64, SSE/NEON: 2×f64).
- **Epoch-based clearing** over bulk zeroing. Flag arrays use generation
  counters (`if (flag[i] == era)`) instead of O(n) memset.
- **Comptime generics.** Every solver monomorphizes per `T` — the compiler
  sees the exact element width and vectorizes accordingly.
- **Frozen CSC pattern.** Sparsity comes from circuit compilation; solvers
  never modify the pattern. Values change per Newton iteration; the pattern
  is immutable.

## Quick start — Newton/JFNK convergence

Generic over any system type via comptime duck-typing. The system provides
`.n`, `.diag_slots`, `.rhs`, `.current_row`; optional: `applyLimits`,
`updateStates`, `clearLimits`. Hook provides `assemble(sys, x, t)` and
`vals(sys)`.

```zig
const converger = solvers.converger;

// Workspace from frozen CSC pattern (one per system)
var ws = try converger.Workspace.init(gpa, n, col_ptr, row_idx, bbd);
defer ws.deinit(gpa);

// Newton options from tolerance bundle
var opts = tol.newtonOpts(null);
opts.gmin = tol.gmin;

// Solve — auto-picks Newton vs JFNK, optional GPU path
const r = try converger.run(&my_system, &ws, x, t, opts, my_hook);
// r.converged, r.iterations, r.max_dx
```

Tolerance presets: `.ngspice` (default), `.hspice`, `.ltspice`, `.tight`.

## Quick start — types (Complex, LogSweep, Waveform)

```zig
const types = solvers.types;

// Complex arithmetic
const z = types.Complex{ .re = 1, .im = 2 };
const m = z.mag();       // 2.236
const db = z.magDb();    // 6.99 dB

// Log-frequency sweep iterator
var sw = types.logSweep(1e3, 1e9, 10);  // 10 pts/decade
while (sw.next()) |f| { ... }

// Waveform measurements
const wf = types.Waveform{ .times = t_data, .values = v_data };
const rms = types.wfRms(wf);
const freq = types.wfFrequency(wf);
const rt = types.riseTime(wf, .{ .lo = 0.1, .hi = 0.9 });
```

## Tests

```sh
zig test modules/solvers/src/root.zig -fno-llvm -fno-lld
```

123 tests covering correctness, determinism, edge cases, and solver-facade
dispatch across all 15 sub-modules.
