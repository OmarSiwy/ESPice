# Lane-centric, data-oriented refactor — evidence log (2026-08-30)

Branch `gpu-device-eval-perf`, commits `f07c7e3..9f80593`. Rules of the run:
tests green at every commit (baseline 296/298 → 305/307; the 2 disto HD2
failures at tests/analyses.zig:972,1070 pre-date the work — verified on clean
HEAD 285e7e7 in a side worktree). No `git stash`; baselines via `git worktree`.

## What changed, by phase

1. **File-level DAG** (`f07c7e3`): leaves import `types.zig`, roots aggregate.
   Cycles killed: solvers root↔direct/bbd/converger, analysis root↔25 leaves,
   root↔contract, Circuit→tran→root→Circuit.
2. **Data reuse + arenas**: tran `a_vals` hoisted into shared Workspace
   (`b5bfa81`); stb reuses the engine op instead of a second DC Newton
   (`6f49d91`); LinCache — planes-hold-linearization-at-x_op is queryable, an
   op+ac+noise+pz deck now does ONE device eval, not four (`f78310e..5c79cf0`);
   NodeIntern — flat bytes+u32 offs, hashmap evicted from the frozen struct
   (`73c6154`); parse/sim/results arenas (`59a1814`, `4ba50a3`); Circuit
   hot/cold regroup (`ee154c9`).
3. **CPU/GPU single source**: HostSink+GpuSink merged into one
   `Sink(D, device, skip_const)` — scatter is `+=` vs `@atomicRmw` behind one
   comptime bool, dedup host-only, ABI untouched (`9ea4224`, net −24 lines);
   `--backend auto|cpu|cuda|hip` with hardware gating, GPU stays opt-in,
   `--gpu` aliased (`9affb0d`); GpuHook lane batches flattened to blobs while
   null (`8a7bac8`).
4. **Lane solvers**: `LaneLu(W)` — W numeric factorizations replaying one
   SparseLu pivot tape, W=1 bit-identical to the scalar oracle, per-lane
   singularity/growth masks (`90ab8ff`); `FreqSolver.solveBatch` W-chunked
   with mid-chunk pivot refresh (`1080472`); ac/noise/stb flipped to
   `gpuFreqBatch orelse solveBatch` (`248a01f`, `bcaeb8b`, `44fa05a`);
   sp/pac/pnoise/pxf NOT flipped — their per-point systems are not pure
   (G+jωC)x=rhs (verdicts in commits); `solveLanes` structural sweep lanes,
   mc −76 lines, temp_sweep −83 (`979e09d`, `2748399`); solver test audit,
   newton_core 0→2 direct tests (`9d635bc`).
5. **Call conventions** (`9f80593`): four `*const`+`@constCast` mutators
   retyped `*Circuit`; pss slice-const strips fixed at the declaration.

## Measurements

### AC lane flip (Phase 4), Debug build, RTX-less CPU path
Deck: 1000-stage RC ladder, n=1002 unknowns, `.ac dec 500 1 1G` = 4501
points. Interleaved 3 runs per binary, `/usr/bin/time`:

| binary | runs | wall |
|---|---|---|
| pre-flip `1080472` | 3 | 1.78 / 1.80 / 1.82 s |
| tip `9f80593` | 3 | 1.54 / 1.55 / 1.64 s |

~13% end-to-end. Raw outputs bit-identical (`cmp` on .raw files) — the flip
is numerically transparent by construction (LaneLu replay preserves scalar
op order; FMA contraction deliberately declined to keep the oracle
bit-identity). Caveats stated plainly: Debug mode (both sides equally);
`suggestVectorLength(f64)` gave W=2 (128-bit) here — ReleaseFast with a
native target widens lanes and should widen the gap; end-to-end includes
parse/eval/output, so the LU-replay speedup is larger than 13% in isolation.

Small decks (21-point rc_lowpass) show no measurable delta — startup
dominates. Expected; the lane axis pays on point count × matrix size.

### Full-suite bench
`zig build bench` at tip completed exit 0. Known pre-existing failures
unrelated to this branch: topology/* accuracy FAILs, tran/fourbitadder inf,
vacask preflight/timestep skips, verilog hdl load errors. The bench harness
truncated scrollback; re-run for a full table when needed.

## Deferred (documented, not built)
- GPU lane-LU RawKernel — solver stays CPU until eval round-trip economics
  flip (gpu_context.zig header states the argument).
- Per-lane GPU instance payloads for solve_batch (sweep lanes on device).
- Sparse augmentation for stb (only if its dense copies ever profile).
- FMA in LaneLu — requires a fused scalar oracle first; bit-identity wins.
- f32 lanes — mechanism generic, policy f64-only (mirrors jac_f32 opt-in).

## Retired ideas, with the evidence that killed them
- `current_row` bitset: bool is <4% of that loop's bandwidth; second reader
  is random-access — a bitset makes it worse.
- `Batch` hot/cold split: O(device types) entries; saves ~a cache line per
  ten batches.
- `MultiArrayList` adoption: hot per-instance stores are already manual SoA;
  proto/batch tables are O(types).
- Lockstep lane Newton for sweeps: divergent iteration counts + per-lane
  limiting = masked complexity, zero flops saved while device eval is serial
  per lane (S-contract branches on scalar values; ParamRef lanes would race
  on shared instance storage).
