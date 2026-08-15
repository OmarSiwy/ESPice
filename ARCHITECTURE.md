# Architecture

ESPice turns a SPICE netlist (ngspice, HSPICE or Spectre dialect, plus
Verilog-A and digital Verilog models) into analysis results: operating
points, sweeps, small-signal, transient, periodic and noise waveforms, written
in one of nine output formats. Parsing and preparation run once per Problem;
the analyses then run as queries on worker threads over one frozen circuit.

Each section gives the **current** state and, where the standard
(`AGENTS.md`) asks for a change, the **target**. A target line names the
block in `dev/plan/standard-adoption.md` that lands it; once it lands, the
current line is deleted.

## Module DAG

Arrows mean "imports". Leaves first.

```
core      std, stdpp
solver    core
device    core, device_abi, contract (VerA), gompute, models (generated), build_options
frontend  core, device
analysis  core, device, solver, gompute
output    core
espice    core, frontend, analysis, output        (src/espice.zig, the Problem facade)
main      espice                                  (src/main.zig; src/c_api.zig likewise)
```

Enforced by: the wiring in `build.zig` (a module sees only the imports it is
handed) and `checkModuleGraph`, which panics at configure time on a cycle or
on an edge `restricted_imports` forbids. Inside a module, `tests/fitness.zig`
ratchets leaf → root imports against `tests/FITNESS.tsv`.

Inside modules, no file imports one that imports it back. The last such
cycle, `frontend/prepare.zig` ↔ `variants.zig`, went in P3: the plan
returns the runs it needs rebuilt (`variants.Rebuild`), and `buildRun`
builds each.

## Spines

- **Problem** (`espice.zig Problem.init`): `frontend.prepare` → `analysis.Session.init` → `Session.append(queries)` → `runSession` (advance until finished) → `output.write` per result.
- **Prepare** (`frontend/prepare.zig prepare`): `source.splitAlters` → `source.expand` → `netlist.parse` → `loadModels` (device `Library.load`) → `loadData` → `buildRun` per run.
- **Build one run** (`prepare.buildRun`): `variants.setPoint` (a rebuilt point) → `buildOne` → `buildRun` per `variants.Rebuild` the plan returned → `setPoint` back to nominal.
- **One run's circuit** (`prepare.buildOne`): `analyses.deckOptions` → `Builder.init` → `NetBuilder.build` → `tagSubcircuitNodes` → `addDynDevices` → `Builder.compilePerm` (`device.Circuit.freeze`) → `NetBuilder.publish` → resolve analysis rows → variant `Planner` → `analyses.queries`.
- **Query** (`analysis/executor.zig run`): `module(kind).run(ctx, job)`, one comptime-dispatched leaf per analysis kind (`dc/op`, `ac/*`, `tran/*`, `pss/*`, `sweep/*`, `post/*`, `eigen/pz`).
- **Newton step** (`solver/converger.zig newton`): `hook.assemble` (→ `Circuit.evalNewton` → device `Batch.eval` per batch) → gmin and force stamps → `normInf(rhs)` → `loadCheck` → `direct.Solver.factor`/`refactor` → `solveNeg` → limit and update `x` → convergence test.
- **Transient step** (`analysis/tran/tran.zig simulate`): `integrator.companionAt` → Newton → `integrator.stepBound` (LTE) → accept (`advanceCurrent`) or reject and shrink.
- **Frequency sweep** (`analysis/ac/freq.zig`): `FreqSolver.setOmega` per lane block → `LaneLu(W)` replay of one pivot tape → `solveBatch` → per-lane failure mask → scalar peel.

The spines are written down here but not yet one-line-per-transform in code
everywhere: `buildOne` and `converger.newton` interleave transforms with
which-work branches. **Target (P3/P6):** the which-work branches move into
the spine as named lines; transforms become straight loops.

## Tables

| Table | Owner (file) | Written by | Read by | Capacity | Arena |
|---|---|---|---|---|---|
| expanded source text | frontend/source.zig | `expand` | netlist | include depth 32 | parse |
| Netlist: pool, graph (csr), values, kvs, ops, consts, models | frontend/netlist.zig | `parse` | builder, analyses, variants | expr depth 512, group depth 32 | session |
| Netlist `deck.alters`, `files` | frontend/prepare.zig | `prepare`, once, before it returns the netlist: they are file reads (each `.alter` run expanded, each `.data` file), and `parse` reads no files | variants, builder (`dataFile`) | per deck | session |
| Netlist live values (`live` slots, `live.scale`, `consts` pool rows) | frontend/netlist.zig | the parse; then only `Netlist.setLive` and `setSlots`, on a `*Netlist` (variants sets each point, prepare a rebuilt one and nominal after) | builder, variants | per deck | session |
| `core.Deck` | frontend/prepare.zig | `buildOne`; **current:** also espice.zig, which rewrites `variants` with the optimizer's and `.mosra`'s rows | analysis, output | per deck | session |
| `Job[]` (analysis cards) | frontend/analyses.zig | `analyses.queries` alone, from the cards and `DeckOptions` (`.sample` included) | prepare, analysis | cards ≤ (2³²−1)/3 | session |
| InternPool | core/intern.zig | frontend | all | u32 ids | session |
| device `Library` (names, vtables) | device/Library.zig | `builtin`, `register`, `load` | builder, analysis | one `DeviceType` per type | Problem |
| frozen `device.Circuit` (pattern CSC, batches, slots, diag_slots) | device/Circuit.zig | `freeze` | analysis | u32 rows/slots | session |
| `DeviceBatch` planes, tapes, limiter state | device/eval.zig | `eval`, `updateState` | analysis Circuit | per batch | query |
| analysis `Circuit` planes (`g`, `c`, `rhs`, `q`, `lin`, `sim`) | analysis/Circuit.zig | Circuit transforms only: the executor installs its contexts through `configure`, `setProgress`, `bindAcParams`, `attachParEval`, `attachDisplay`, `attachGpu`/`detachGpu` (which move the planes onto the GPU context's page-locked buffers and back) and `attachLu`; dc/op through `rebuildBaseline` and `attachDisplay`, the transient through `landRejects`/`clearRejectAt` | solvers, analyses | nnz, n | query |
| SparseLu pivot tape, L/U values | solver/sparse_lu.zig | `factor`, `refactor` | direct, lane_lu | nnz fill | query |
| Session rows, Results | analysis/session.zig | executor results | facade, output | u32 query ids | result |
| output streams | output/session.zig | `publish` | writers | per format | Problem |

## Seams

Full records: `dev/decisions.md`.

| Seam | Axis | Rung | Record |
|---|---|---|---|
| Analysis kind dispatch (`executor.module(kind)`) | kind | 5 `inline else` over `requests.Kind` | S1 |
| Device type evaluation (`Batch` + `Hooks`) | kind (one per `DeviceType`, loaded at runtime too) | 7, once per batch per eval | S2 |
| Device derivative scalar `Dual(N, F)` | policy (derivative lanes, f32/f64 Jacobian) | 5 | S3 |
| Device target (`Sink(comptime device)`) | backend: host, CUDA, HIP | 5 | S4 |
| GPU evaluation and LU contexts (`Circuit.gpu`, `Circuit.lu`) | backend at runtime | 1, concrete optional contexts; one branch per evaluation entry, folded away in a host-only build | S5 |
| Frequency lane width (`LaneLu(W)`) | policy: W = 1 (oracle) … 4 | 5 | S6 |
| Linear engine (`direct.Solver`) | kind: sparse LU, tridiagonal, BBD | 4, `direct.Engine` `union(enum)` | S7 |
| Netlist dialect | dialect: ngspice, HSPICE, Spectre | 3 (keyword tables per dialect) | S8 |
| Output format | kind: 9 encoders | 4 switch in `output/write.zig` | S9 |
| Runtime HDL devices (`loader.zig`, `.so` + `layout_hash`) | plugin | 9 | S10 |

## Invariants

- `solver` is imported only by `analysis`; `analysis` never imports `frontend` or `espice`; `output` never imports `analysis` (§2.8).
- `device/eval.zig` imports no stdpp and no host-only module: it is also the GPU kernel and runtime `.so` root.
- The GPU boundary layouts are frozen behind `abi_version` and `layout_hash` (§2.9).
- Every plane or parameter writer clears `Circuit.lin.x_ptr`/`lin.valid`.
- A lane kernel's `W == 1` instantiation is its oracle; failed lanes peel to the scalar path.
- Nothing below the facade reads or writes the environment. `espice.zig` reads the developer switches once per Problem (`knobsFromEnv`) into `ExecutionConfig.knobs` (`analysis.Knobs`), which reach the code as `Circuit.knobs`, `Workspace.knobs` and `Solver.knobs`; fills `Library.toolchain`'s `zig` and `cache_dir` (`toolchainFromEnv`); and raises `CUDA_CACHE_MAXSIZE` (`raiseJitCache`) before any query can bring the driver up.
- No file-scope mutable state, with one exception, `device/eval.zig staging_gpa` (**target:** a later block). Whether the GPU driver is up is the Problem's (`Problem.gpu_driver`, lent to every query through `ExecutionConfig.gpu_driver`). `numerics.opaque_zero` and `SparseLu.opaque_zero` are never written, and stay `var` as optimizer barriers because Zig folds a volatile read of a `const`.
- **Target (P3):** no `anyerror` across a module boundary (today: espice.zig, session/worker, gpu).

## Adding a feature

- **A new analysis** → a request variant in `core/query.zig`, a leaf in `analysis/<family>/`, an arm the compiler lists in `executor.module`, a schema in `session.schemaOf`, a card in `frontend/analyses.zig`, fixtures in `tests/fixtures/<name>/`, a `docs/using/analyses.md` entry.
- **A new built-in device** → a `.va` in `models/` (discovered by `build.zig`); the SPICE letter/LEVEL mapping row in `frontend/spice.zig`; fixtures against ngspice.
- **A new netlist card or option** → a row in the `cards` `StaticStringMap` (`frontend/netlist.zig`) and its parse transform; an unsupported one is refused by name with a `tests/fixtures/invalid/` case.
- **A new output format** → an encoder file in `output/`, a `Format` tag, the compiler-listed arm in `output/write.zig`, a schema check in `validateQuery`.
- **A new linear engine** → a `direct.Engine` variant and its compiler-listed arms.
- **Outside code needs to change a table** → a request table its owner drains.

## Change drill

Drills and their verdicts: `dev/decisions.md` § Drills.
