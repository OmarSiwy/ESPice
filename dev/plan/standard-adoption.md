# Adopting the VerAReWrite design standard

Source: `../VerAReWrite/AGENTS.md` (the design review R0–R10, §2 overrides,
Principles Parts I–VII). Procedure: `codebase-improvement`. The architecture
may change freely (user, 2026-10-17); observable behaviour may not: the
fixture corpus verdicts (PASS and XFAIL name lists) are the oracle.

## Inventory (step 1): 56 blocks, 135 files, ~66k lines

Whole-repo numbers: 94 runtime asserts over ~2063 functions (target 2/fn);
207 `else =>`, none annotated `// else:`; 24 `anyerror`; 0 fuzz tests;
19 `checkAllAllocationFailures`; 0 codegen probes; 0 hot-struct `@sizeOf`
asserts; 4 files without `//!` (frontend/tests/*). No ARCHITECTURE.md,
GLOSSARY.md, TESTING.md, ADRs. CI (`nix.yml`) runs `nix flake check`
(build + 2-deck smoke) only: `zig build test` never runs in CI.

### Hot blocks (evidence: callgrind notes in dev/)

| Block | Files | Evidence |
|---|---|---|
| device eval | device/eval.zig (2934) | `DeviceBatch(mos*).eval` 45.9–50.3% self (evaluation-profile.md:86) |
| device ABI types | device/abi.zig | `Batch.eval` per Newton iter per batch |
| circuit-core | analysis/Circuit.zig, types.zig | `evalNewtonCpu` 54.5% incl. (evaluation-profile.md:85) |
| par_eval | analysis/par_eval.zig | per-eval stamp when device_threads>1 |
| sparse LU | solver/sparse_lu.zig, order.zig | factor 70%, refactor 19–23% (solver-perf-2026-09.md:22-28) |
| direct facade | solver/direct.zig, tridiag.zig | 8.8% + 2.6% (evaluation-profile.md:88,93) |
| bbd | solver/bbd.zig | 21.8% (refactor-tape-2026-09.md:46) |
| freq lanes | solver/lane_lu.zig, freq_solve.zig | 20.3% (solver-perf-2026-09.md:23) |
| converger | solver/converger.zig | 14.2% (solver-perf-2026-09.md:27) |
| numerics | core/numerics.zig | `normInf` inside Newton (converger.zig:217) |
| dc op | analysis/dc/op.zig | ~1 ms/Newton iter (solver-perf-2026-09.md:37) |
| ac sweep | analysis/ac/freq.zig + drivers | solveBatch 1654M→772M Ir |
| tran core | analysis/tran/tran.zig, integrator.zig | stepBound 2.7% etc. (evaluation-profile.md:92) |
| lines | frontend/lines.zig | bench-frontend; frontend.md:483 |
| netlist parse | frontend/netlist.zig, csr.zig | bench-frontend |
| builder | frontend/builder.zig, spice.zig | preparation-performance.md 36.8→22.5 ms |

The other 40 blocks are cold (no evidence). Cold + tested + documented gets
nothing beyond the repo-wide gates.

### Architecture flags (fixed hot or cold)

- Cycles: `core/deck.zig`, `core/query.zig` → `core/root.zig`;
  `frontend/prepare.zig` ↔ `variants.zig` (why `buildRun` is `anyerror`);
  `device/root.zig` ↔ `Library.zig` ↔ `loader.zig`.
- Multiple writers: netlist consts/live via `@constCast` from variants and
  prepare (netlist.zig:411,1948,1965,3262); analyses `Job[]` mutated in
  prepare.zig:320; analysis `Circuit` fields assigned from executor, dc/op,
  tran; `Batch.digital` from device and analysis Circuit.
- Globals: converger env-cache atomics (:38,56-58), `numerics.opaque_zero`,
  `gpu.zig:150 driver_up` (racy per its comment), `eval.zig:991
  staging_gpa`, `device/Circuit.zig:73` uses `core.gpa`; 11 `getenv` in the
  factor path.
- Implicit union: `direct.Solver` engine as three optionals.
- `anyerror` across module boundaries: espice.zig (public), session/worker,
  gpu, loader, prepare.
- Oversized files with internal seams: eval.zig, netlist.zig, builder.zig,
  gpu.zig, analyses.zig.

### Bugs found by the sweep (each gets an issue + regression test + oracle)

| # | Bug | Status |
|---|---|---|
| 1 | `analysis/tran/matex.zig` expmSmall loops forever when H holds an inf | #125, fixed in P2 |
| 2 | `device/eval.zig permuteInPlace` loops forever on a non-permutation | open; waits for #117 (eval.zig is being changed by another session) |
| 3 | `analysis/par_eval.zig waitCount` spin has no iteration bound | not a bug: every lane runs infallible work and a dead worker panics the process, so the wait ends; it gets a comment stating the progress argument in P5. Its worker-spawn `@panic` on a thread failure is an operating error to return (P5) |
| 4 | `analysis/gpu.zig driver_up` data race | #126, atomic in P2; the global moves to its owner in P3 |
| 5 | C ABI raw handles (use-after-destroy is UB); `catch unreachable` in `espice.zig deliverFrom` reachable from `espice_advance*` | P3 (generational handles, named errors) |
| 6 | Docs promise asserts that do not exist (15 in frontend, `Library.vtable`) | P5 |
| 7 | `device/eval.zig dedupModels` `@memcpy` onto itself (UB; 99 aborts in a safety-checked build) | #122, fixed |
| 8 | `analysis/tran/types.zig Column.from(len)` slices past a strided base | #123, fixed |
| 9 | mosra test passes tolerance 0 to `expectApproxEqRel` | #124, fixed |

7–9 were found by running the suites with safety checks on (Debug), which is
why the gate now runs ReleaseSafe (AGENTS.md §2.5). Debug itself also shows
self-hosted-backend divergence (#25): three numeric mismatches, a
`pthread_create` EINVAL under `std.testing.io`, and a
`NondeterministicMemoryUsage`; Debug joins the gate when #25 closes.

## Plan (step 3)

Each phase lands as one-step commits with `zig build test -Doptimize=ReleaseSafe`
green and the corpus name lists unchanged. P3–P6 blocks run as agents in their
own worktrees branched from `standard` (at most two building at once), merged
back by name-list-checked gates.

### Progress (2026-10-17)

- P0 done: AGENTS.md, dev/principles.md, ARCHITECTURE.md, dev/decisions.md, GLOSSARY.md, TESTING.md.
- P1 done: `checkModuleGraph`, tests/VERDICTS.tsv ratchet, tests/fitness.zig + FITNESS.tsv, tests/codegen.zig (`Dual.mul` IDENTICAL), CI test.yml. ReleaseFast stays the default (user); the gate runs ReleaseSafe.
- P2: #122–#126 fixed; 2, 5, 6 scheduled as above.
- P3 running: `p3-cycles` (core/device cycles, loader error set), `p3-solver` (S7 union, env knobs to Config).

**P0 Adopt the standard (docs only).** AGENTS.md becomes the VerAReWrite
standard with an ESPice §0.3 (Zig 0.17 via `nix develop`, ngspice/VACASK
oracle, CPU/CUDA/HIP targets, artifact paths under `dev/` because `docs/` is
the mkdocs site) and §2 overrides that carry today's ESPice rules (DAG,
lane-axis doctrine, stdpp loop rules, CPU/GPU freeze, call conventions, proof
rule, CHANGELOG/issue/worktree git rules). Then `ARCHITECTURE.md` (target
design), `dev/decisions.md` (seam records + three drills from the issue
backlog), `GLOSSARY.md`, `TESTING.md`, `dev/adr/`, `dev/reviews/`.

**P1 Gates (fitness functions).** CI job running `zig build test
-Dgpu=false` in Debug and ReleaseSafe; corpus PASS/XFAIL name-list ratchet;
`module_specs` resolver in build.zig that panics on a forward import; test
that fails on an unannotated `else =>` over a boundary enum (annotate or
make exhaustive the 207 sites); `//!` header test; codegen-probe step
(`zig/scripts/asm_probe.py`) for the hot rung-5 seams `Dual`, `Sink`,
`DeviceBatch`, `LaneLu(W)`, `converger.newton(anytype)`; `@sizeOf`
asserts on hot structs.

**P2 Bugs 1–6**, one issue and commit each (`diagnosing-bugs`).

**P3 Architecture.** Break the three cycles; one owner per table (netlist
live values and `Job[]` through request tables drained by their owner;
analysis `Circuit` writes through owner transforms); globals and `getenv`
become explicit config read once at session init; `direct.Solver` becomes
a tagged union; named error sets replace `anyerror`; generational C ABI
handles; split eval.zig, netlist.zig, builder.zig, gpu.zig, analyses.zig
along their seams.

**P4 Oracles (R7).** Structure-aware netlist fuzz (Smith) with the declared
error set as oracle; `checkAllAllocationFailures` on source, builder,
analyses, loader, session, C ABI; KCL residual certificate on converged OPs;
scaled LU residual; Jacobian vs finite difference for every model;
`solver_threads`/`device_threads` 1 vs N byte identity; integrator order by
manufactured solutions; direct CPU-vs-CUDA differential.

**P5 Contracts on cold blocks.** Asserts toward 2/fn, stated capacities,
bounded loops, doc-comment audit. No layout work.

**P6 Hot blocks, full chain** (the 16 above), each with `zig build bench`
or callgrind before/after. A change that does not move the number is
reverted.
