# ESPice (espice) — SPICE circuit simulator in Zig

Analog circuit simulator: SPICE netlists in, DC/AC/tran/PSS/noise/sweep
analyses out. Devices are compiled from Verilog-A at build time (VerA),
GPU compute goes through gompute. Siblings this tree depends on by path:
`../gompute`, `../VerA`, `benchmark/` (see build.zig.zon).

## Skills: load these before implementing, every session

Before writing or reviewing any code in this repo, load these skills via the
Skill tool. This is not optional and not "when relevant". The order matters:
design constraints first, code-minimization last.

1. `/data-oriented-design`. Answer the six questions in writing before any new
   struct or table. SoA by default, indices not pointers, arena by lifetime,
   narrowest type the stated range allows.
2. `/simd-first` (local, `.claude/skills/simd-first`, reference in
   `ref/SIMD-Strategies/`). Scalar oracle first, then the vector kernel, then
   read the asm. Every kernel adds a differential case against its scalar
   oracle: in `ref/SIMD-Strategies/verify.zig` when the kernel is
   self-contained (that file runs standalone under `zig run`, so it can
   import nothing from `src/`), otherwise in the matching `src/analysis/tests/` suite with a
   pointer to it from verify.zig — LaneLu is the worked example.
3. `/ponytail`. After the data layout and kernel strategy are fixed, write the
   least code that satisfies them. YAGNI applies to everything except
   correctness at trust boundaries and the conformance gates.
4. Clean code: there is no `/unslop` skill installed; the equivalent here is
   `/code-review` before merging and `/simplify` after a phase lands, plus the
   org writing rules for docs and comments. If an `unslop` skill gets
   installed later, load it here.

Conflict rule: data layout beats code brevity. Ponytail decides how little
code we write, never what shape the data takes.

## The dependency DAG (enforced by convention, checked at review)

The public feature modules are `frontend`, `problem`, `analysis`, and `output`.
Main and the C adapter call the owning Problem API. Problem coordinates frontend
preparation, analysis execution, and output delivery.

Shared leaf modules (`problem_types`, `requests`, `numerics`, `device_ir`,
`output_types`) hold data contracts. Frontend produces a passive Prepared
circuit; analysis consumes it without importing frontend or Problem's owning
facade. Output consumes the shared result schema without importing analysis.
Model sources live in `models/`; device construction and HDL loading live in
`src/frontend/`; numerical evaluation and GPU policy live in `src/analysis/`.

**Solvers are private to `src/analysis/solvers/`. No source outside
`src/analysis/` may import solver modules or expose solver implementation types.**
Cross-layer tests needing solvers belong inside analysis as well.

File-level rule: **leaves import shared types/other leaves, never their module's
`root.zig`**. Roots aggregate and re-export. Shared analysis RunCtx/Result and
mutable Circuit aliases live in `analysis/types.zig`; passive construction
contracts live in `problem/types.zig`. Solver-independent settings are in
`problem/numerics.zig`; `tran/types.zig` owns transient shared types. Do not
close a cycle through an aggregation root.

## Lane-axis doctrine (SIMD-first as architecture)

The lane axis (N independent instances of one transformation) is designed
in, not retrofitted per-loop:

| Axis | Mechanism |
|---|---|
| Frequency points (ac/noise/sp/stb/pac/pnoise/pxf) | SIMD lanes: `LaneLu(W)` replay of one SparseLu pivot tape; `FreqSolver.solveBatch` |
| Sweep points (mc/temp/sens/dcmatch) | Structural lanes: `sweep/lanes.zig solveLanes` (GPU `solve_batch` orelse serial) |
| Device derivatives | `Dual(N, F)` forward AD (analysis/eval.zig) |
| Device instances | ParEval worker threads |

NOT lanes (do not try): tran timesteps (sequential in t), Newton iterations,
HB harmonics (coupled through the nonlinearity), pss shooting.

Scalar oracle = the `W == 1` instantiation of the same kernel, never a
second code path. Lane kernels return per-lane failure masks; bad lanes are
peeled to the scalar full-factor ladder (see analysis/solvers/direct.zig fallback).

## CPU/GPU sharing

No GPU-only kernel logic. Kernel code lives once in the shared path
(analysis/eval.zig `evalRange` + `Sink(comptime device)`); gompute compiles
it for host, CUDA and HIP. The same file serves as each device's build root
and exports that device's entry points at comptime. Backend is a runtime
choice (`--backend auto|cpu|cuda|hip`), gated by the hardware probe.
Batch solve call sites are `gpu_hook.X(...) orelse cpu.solveBatch(...)` —
one lane-shaped flat-blob signature both ways.

FROZEN at the GPU boundary (ABI + layout_hash): scatter tapes
(gath/rhs_idx/slots u32 layout), Model/Instance PODs, pattern CSC and plane
`[]f64` layout. Redesign host tables around them, never through them.

## Call conventions (zero-cost by choice)

- Immutable input → by value `T` (Zig passes big structs by hidden reference
  itself; by-value is the zero-cost default and states immutability).
- Callee mutates → `*T`. Large + identity matters → `*const T`. Never
  `*const` on small PODs.
- Non-mutating methods take `self: Self` (or `*const Self` when large).
- Cross-object references are u32 indices into tables, never stored
  pointers. Allowed pointers: fn-pointer dispatch tables (Batch vtable —
  O(device types) indirect calls per eval), slices into owned storage,
  ParamRef.ptr (frozen-storage contract), and `Circuit.lin.x_ptr` — an
  identity key, never dereferenced, comparing the arena slice x_op was
  built from. Every plane or parameter writer clears it (`Circuit.eval`
  included), so a freed-and-reused address cannot read as a cache hit.

## Zig idioms, mandatory

- `std.StaticStringMap` for every fixed string set (analysis keyword map in
  problem/requests.zig is the template).
- SoA with explicit hot/cold splits for hot tables (SparseLu, DeviceList are
  the templates). AoS only when all fields are read together per iteration
  (Batch is the documented exception).
- `enum`-typed / u32 handles for every index space; narrowest integer the
  stated range allows.
- Arenas by lifetime: parse scratch (dies after preparation), session arena
  (prepared template/source), per-query work and result arenas. Completed
  results and prerequisite products remain valid until Problem destruction.
- Comptime existence (`if (has_X) T else void`, analysis/eval.zig
  DeviceBatch) over runtime optionals in per-element hot paths.

## The proof rule

Every performance claim ships with a `zig build bench` before/after in the
commit message. Every intentional divergence or retired experiment is noted
in docs/ with its fallback. "It feels cleaner" proves nothing. Deliberate
shortcuts carry a `ponytail:` comment naming the ceiling and upgrade path.

## Verification

- `zig build && zig build test` after every step. Historical baseline: 305/307 —
  the 2 `disto` HD2 failures pre-date the refactor (verified on clean HEAD
  285e7e7 in a worktree). Their assertions moved with the module split; the
  analysis-contract suite is `src/problem/tests/analyses.zig` now, and the
  remaining distortion gap is tracked as C7 in `issues.md`.
- The numeric deck corpus is `tests/fixtures/**`. A deck that a feature does
  not cover yet says so IN THE DECK (`* KNOWN GAP: ...`) and is expected to
  fail until the feature lands — `issues.md` is the audited index of them.
- New SIMD kernels: differential test vs the scalar oracle in
  `ref/SIMD-Strategies/verify.zig`, plus an asm spot-check that the expected
  vector instruction is emitted. The build has no backend flag any more (the
  native backend is always on), so read the asm off a direct invocation:
  `zig build-obj -OReleaseFast -fllvm -femit-asm=/tmp/k.s --dep numerics -Mroot=src/analysis/solvers/direct.zig -Mnumerics=src/problem/numerics.zig`.
- GPU: default build compiles device kernels; `--backend cuda` on absent
  hardware must error naming what was detected.

## Git rules

- **NEVER `git stash`.** For baselines use a worktree:
  `git worktree add ../espice-base <rev>` (relative-path deps require the
  worktree to sit beside `../gompute`/`../VerA`, NOT in /tmp).
- One step per commit; tests green at every commit.
