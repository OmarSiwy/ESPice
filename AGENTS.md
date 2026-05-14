# ESPice: a SPICE circuit simulator in Zig

SPICE netlists in; DC, AC, transient, periodic, noise and sweep analyses
out. Device models are Verilog-A compiled at build time by VerA, and GPU
device evaluation goes through Gompute. Both are pinned git dependencies in
`build.zig.zon`; to co-develop one, point its entry at a local `.path` and
restore the pin before pushing. The benchmark runner lives in
`tests/benchmark/`.

## Skills: load these before implementing, every session

Load these skills with the Skill tool before writing or reviewing any code
here, every time. The order matters: design constraints first, code
minimization last.

1. `/data-oriented-design`. Answer the six questions in writing before any new
   struct or table. SoA by default, indices not pointers, arena by lifetime,
   narrowest type the stated range allows.
2. `/simd-first` (local, `.claude/skills/simd-first`, reference in
   `ref/SIMD-Strategies/`). Scalar oracle first, then the vector kernel, then
   read the asm. Every kernel adds a differential case against its scalar
   oracle: in `ref/SIMD-Strategies/verify.zig` when the kernel is
   self-contained (that file runs standalone under `zig run`, so it can
   import nothing from `src/`), otherwise in the owning module's test suite
   (`src/solver/tests.zig`, `src/analysis/tests/`) with a pointer to it from
   verify.zig. LaneLu is the worked example.
3. `/ponytail`. After the data layout and kernel strategy are fixed, write the
   least code that satisfies them. YAGNI applies to everything except
   correctness at trust boundaries and the conformance gates.
4. Clean code: `/code-review` before merging, `/simplify` after a phase
   lands, `/doc-comments` for every `pub` declaration, and `/humanizer` for
   docs and comments.

Conflict rule: data layout beats code brevity. Ponytail decides how little
code we write, never what shape the data takes.

## The dependency DAG (enforced by build.zig wiring)

A module can only import what build.zig hands it, so the wiring is the DAG:

```
core     src/core/          std only: ids (DeviceType, QueryId, Name), InternPool,
                            numerics, query requests, Deck, Result/Schema, GROUND
solver   src/solver/        core
device   src/device/        core, device_abi (abi.zig), models, fastvaf (VerA),
                            build_options; eval.zig also builds standalone as
                            device_eval
frontend src/frontend/      core, device
analysis src/analysis/      core, device, solver, gompute
output   src/output/        core
espice   src/espice.zig     core, frontend, analysis, output (the Problem facade)
main     src/main.zig       espice only; src/c_api.zig likewise
```

**Only `analysis` imports `solver`.** build.zig wires `solver` into the
analysis module and its test root and nowhere else, so an import from any
other module does not compile. Cross-layer tests that need solvers belong
inside analysis.

**Only `device` deals with devices.** It owns the neutral ABI (`abi.zig`), the
evaluator (`eval.zig`, also the per-model host-object, GPU-kernel and runtime
`.so` build root), the parameter binder (`bind.zig`), HDL loading
(`loader.zig`), the frozen `Circuit` (`Circuit.freeze`) and the per-Problem
`Library`: one dense `DeviceType` id per device type, built-in or
runtime-loaded. The SPICE letter and LEVEL policy stays in
`frontend/spice.zig`. The runtime loader rebuilds `eval.zig` by path, so the
`dyn_path`, `device_abi_path` and `core_path` build options must follow any
move of those files.

Frontend produces `Prepared = {circuit: device.Circuit, deck: core.Deck}`;
analysis takes the two separately (`Session.init(gpa, io, circuit, deck,
config)`) and never imports frontend or the facade. `analysis.schemaOf`
describes a query's result before it runs and `output.validateQuery` decides
whether a format can hold it, so output never imports analysis. Model sources
live in `models/`.

File-level rule: **leaves import shared types/other leaves, never their module's
`root.zig`**. Roots aggregate and re-export. Shared analysis RunCtx/Result and
mutable Circuit aliases live in `analysis/types.zig`; `tran/types.zig` owns
transient shared types. Do not close a cycle through an aggregation root.

## Lane-axis doctrine (SIMD-first as architecture)

The lane axis (N independent instances of one transformation) is designed
in, not retrofitted per-loop:

| Axis | Mechanism |
|---|---|
| Frequency points (ac, noise, stb, sp through `ac/freq.zig`) | SIMD lanes: `LaneLu(W)` replay of one SparseLu pivot tape; `FreqSolver.solveBatch`, every rhs (sp: one per port) per factorization. pac, pxf and pnoise still solve per point |
| Sweep points (mc/temp/sens/dcmatch) | Structural lanes: `sweep/lanes.zig solveLanes` (serial over lanes) |
| Device derivatives | `Dual(N, F)` forward AD (device/eval.zig) |
| Device instances | ParEval worker threads |

Not lanes, do not try: transient timesteps (sequential in t), Newton
iterations, HB harmonics (coupled through the nonlinearity), PSS shooting.

The scalar oracle is the `W == 1` instantiation of the same kernel, never a
second code path. Lane kernels return per-lane failure masks, and failed
lanes peel to the scalar path, whose full factor re-pivots (see
`solver/freq_solve.zig` and the `solver/direct.zig` fallback).

## CPU/GPU sharing

No GPU-only kernel logic. Kernel code lives once in the shared path
(device/eval.zig `evalRange` + `Sink(comptime device)`); gompute compiles
it for host, CUDA and HIP. The same file serves as each device's build root
and exports that device's entry points at comptime. Backend is a runtime
choice (`--backend auto|cpu|cuda|hip`), gated by the hardware probe. The GPU
evaluates device planes (`Circuit.gpu_hook.eval_planes`); every solve runs on
the host.

FROZEN at the GPU boundary (ABI + layout_hash): scatter tapes
(gath/rhs_idx/slots u32 layout), Model/Instance PODs, pattern CSC and plane
`[]f64` layout. Redesign host tables around them, never through them.

## Call conventions (zero-cost by choice)

- Immutable input: by value `T`. Zig passes big structs by hidden reference
  itself, so by-value costs nothing and states immutability.
- Callee mutates: `*T`. Large and identity matters: `*const T`. Never
  `*const` on small PODs.
- Non-mutating methods take `self: Self` (or `*const Self` when large).
- Cross-object references are u32 indices into tables, never stored
  pointers. Allowed pointers: function-pointer dispatch tables (the Batch
  vtable, O(device types) indirect calls per eval), slices into owned
  storage, `ParamRef.ptr` (frozen-storage contract), and
  `Circuit.lin.x_ptr` (`analysis/Circuit.zig`). That last one is an identity
  key comparing the arena slice x_op was built from, never dereferenced.
  Every plane or parameter writer clears it, `Circuit.eval` included, so a
  freed and reused address cannot read as a cache hit.

## Zig idioms, mandatory

- `std.StaticStringMap` for every fixed string set (the card keyword map
  `cards` in frontend/netlist.zig is the template).
- SoA with explicit hot/cold splits for hot tables (`SparseLu` and the
  `frontend/csr.zig` hypergraph are the templates). AoS only when all fields
  are read together per iteration (Batch is the documented exception).
- Enum-typed or u32 handles for every index space; the narrowest integer the
  stated range allows.
- Arenas by lifetime: parse scratch (dies after preparation), session arena
  (prepared template/source), per-query work and result arenas. Completed
  results and prerequisite products remain valid until Problem destruction.
- Comptime existence (`if (has_X) T else void`, device/eval.zig
  DeviceBatch) over runtime optionals in per-element hot paths.

## The proof rule

Every performance claim ships with a measured before/after in the commit
message: `zig build bench` for wall time, callgrind instruction counts when
the machine is too noisy for wall time. Every intentional divergence from
ngspice or VACASK, and every retired experiment, is recorded in `docs/` with
its measurements and fallback. "It feels cleaner" proves nothing. Deliberate
shortcuts carry a `ponytail:` comment naming the ceiling and upgrade path.
Session notes and handoffs do not go in `docs/`: fold their durable facts
into the topical page before the branch merges.

## Verification

- `zig build && zig build test` after every step. `zig build test` runs the
  unit suites and then the numeric corpus. Baseline at `321044c`: every
  unit test passes (295 across the eight per-area steps, plus the corpus
  harness's own tests), and the corpus scores 560/616. The step exits
  nonzero while any deck fails, so compare the failing set, not the exit
  code: no deck on the pass list may start failing. All `disto` decks pass;
  the analysis-contract suite is `src/tests/analyses.zig`.
- The numeric corpus is `tests/fixtures/**`. A deck whose feature is
  missing says so in the deck (`* KNOWN GAP: ...`) and is expected to fail
  until the feature lands. `issues.md` is the audited index of failing
  decks and their causes.
- Timing-sensitive decks (`stress/scaling_inverter_chain_4k`) can time out
  on a loaded machine; check the failure reason before calling it a
  regression.
- A CPU-only build (`-Dgpu=false`) compiles much faster and is enough for
  host-only changes. Anything that touches the device ABI, the Circuit GPU
  hooks or `analysis/gpu.zig` also needs the default build, which compiles
  the device kernels. `--backend cuda` on absent hardware must fail with an
  error naming what was detected.
- New SIMD kernels: a differential test against the scalar oracle (see the
  skills list), plus an asm spot-check that the expected vector instruction
  is emitted. Read the asm off a direct invocation:
  `zig build-obj -OReleaseFast -fllvm -femit-asm=/tmp/k.s --dep core -Mroot=src/solver/direct.zig -Mcore=src/core/root.zig`.

## Git rules

- **Never `git stash`.** For a baseline, use a worktree:
  `git worktree add ../espice-base <rev>`. With the pinned dependencies a
  worktree builds anywhere; one that points a dependency at a local `.path`
  must keep that relative path valid.
- One step per commit, tests green at every commit.
