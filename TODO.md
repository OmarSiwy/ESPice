# TODO — Parallelism (multi-thread / GPU)

Profile data (2026-07-04, `benchmark/profiles/*.svg`): nonlinear circuits spend ~48% in
`batch.DeviceBatch(T).eval` (+ exp/log), ~17% in `direct.SolverT(f64).factor`, ~5% in
`Lu.solve`. Big linear netlists are parse/build-bound instead — parallelism doesn't help
those; see "Not parallelism" at the bottom.

**Golden rule (GPU):** one upload per analysis, one download per analysis. Topology,
`slots`/`gath`/`rhs_idx` index arrays, model params, and instance SoA go up once before
the analysis starts. `x`, `rhs`, `g_vals`, `c_vals`, `q_vec` stay device-resident across
ALL Newton iterations and ALL timesteps. Only waveform outputs come back, at the end (or
in large chunks if memory forces it). If any design point requires a per-iteration
round-trip, the design is wrong — restructure so the whole NR loop lives on the device.

## Wiring points

### 1. Multi-threaded device eval (do first — cheapest, covers ~48%)

- **Where:** `modules/analysis/src/root.zig:323` (`Circuit.eval`) and `:336`
  (`evalNewton`) — currently serial `for (self.batches) |b| b.eval(...)`.
  Inner loop: `modules/analysis/src/batch.zig` `evalInner` (`for (0..self.count) |id|`)
  — SoA, no cross-instance deps except the scatter-add into `ckt.rhs` / `ckt.g_vals`.
- **How:** `std.Thread.Pool`. Chunk `0..count` per batch; parallelize across batches too
  (they share the same scatter targets). Scatter conflict resolution, pick one:
  a) per-thread `rhs`/`g_vals` accumulation buffers + reduce (simple, memory = n_threads × nnz), or
  b) slot coloring so no two concurrent chunks share a slot (precompute in `PatternBuilder`).
  Start with (a).
- **Caution:** the eval-dedup cache (`eval_cache_hash` in `evalInner`) is shared mutable
  state — make it per-thread or skip dedup on the MT path and measure.
- **Threshold:** spawn threads only above ~1k instances per batch; below that, serial.
  Thread-pool dispatch overhead beats the win on small circuits.

### 2. Parallel block factorization (covers the 17% LU)

- **Where:** `modules/solvers/src/direct.zig` `SolverT(f64).factor`. BBD support already
  exists: `modules/solvers/src/root.zig:13` `BbdInfo` — independent diagonal blocks +
  coupling border.
- **How:** factor `BbdInfo.blocks` in parallel (thread pool), then the coupling border
  serially. Sweep-style netlists (e.g. `benchmark/fixtures/sweep/opamp_wl_5000`, 5000
  electrically independent instances) become near-embarrassingly parallel.
- **Prereq:** something must *populate* `BbdInfo` — connected-component detection over
  the node graph in `src/builder.zig` (policy layer, per architecture decision B).

### 3. Coarse-grain analysis parallelism (biggest win per line of code)

- **Where:** analysis drivers in `modules/analysis/src/` — `mc.zig` (Monte Carlo
  samples), `dc.zig` (sweep points), `temp_sweep.zig`. Each point is an independent
  solve.
- **How:** one `Circuit` + `newton.Workspace` clone per thread, thread pool over points.
  No scatter conflicts, no shared state — this is the easy near-linear speedup.

### 4. GPU device eval + batched solve (last — only after 1–3 measured insufficient)

- **Kernel body:** `D.evalFromPrep(S, xd, pc, model, instance, t)` in
  `modules/analysis/src/batch.zig` `evalInner` is already a pure function of gathered
  node voltages + SoA params. Wrap per-model in `callconv(.kernel)` (NVPTX/AMDGCN) or
  `callconv(.spirv_kernel)` entry points; one thread = one instance `id`. Annotate every
  device pointer `addrspace(.global)` — unannotated pointers silently land in
  per-thread local memory on the SPIR-V path.
- **Scatter on device:** reuse the precomputed `slots` / `rhs_idx` arrays; atomicAdd
  into `g_vals`/`rhs`, or segmented reduction if atomics contend.
- **Residency boundary:** `modules/analysis/src/newton.zig:41` (`newton.solve`) — the
  whole loop (eval → gmin → factor → solveNeg → clamp → limits) must run device-side.
  Factor via batched dense LU per BBD block (`dense_lu.zig` is the CPU reference);
  border solve can stay on CPU only if the border is tiny AND transferred
  asynchronously — otherwise device.
- **Upload once:** at analysis start (`tran.zig` / `dc.zig` / `ac.zig` entry), after
  `Simulation.fromNetlist`. Download once: waveform buffer at analysis end.
- **Convergence check:** `max_dx < abstol` needs a device-side reduction to a single
  flag; read back one u32 per iteration at most (pinned memory), never the state vector.
- **Plumbing:** `--gpu` flag parse in `src/main.zig` (benchmark runner already passes it,
  `benchmark/src/runner.zig:133`).
- **Cutover:** dispatch GPU only when total instance count clears a measured threshold
  (likely ~10k+); CPU path stays the default.

## Not parallelism (but currently the wall-clock king on big netlists)

- Parse/build: tokenizer + parser + `PatternBuilder.add` + `internNode` + arena alloc
  ≈ 60–70% on `rc_ladder_100k`. Cut allocation churn first; chunk-parallel tokenize
  only if that's not enough.

## Bugs blocking benchmark trust (fix before perf work)

- SIGSEGV (rc=139): `devices/vbic_noise_scale`, `devices/bsim4_transfer`
- `OpDidNotConverge`: `sweep/opamp_wl_*`, `scaling/inverter_chain_*`, `tran/fourbitadder`
  — burns full iteration budget, then fails; convergence fix will reshape the profile.
