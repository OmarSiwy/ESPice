# HANDOFF_RESEARCH — open threads after the GPU build unblock

Picks up where `HANDOFF.md` (gompute issues, all resolved upstream in 1.0.0)
left off. That doc was about *building*; this one is about the fact that
`zig build bench` now builds and runs and is still not right.

Each thread is labelled with how much is actually established:

- **PROVEN** — read the code and/or ran it; the cited chain closes.
- **LEAD** — strong evidence, one inference not yet checked.
- **OPEN** — symptom observed, cause unknown.

---

## Baseline

State as of this handoff (`modules/devices/build.zig.zon` pins gompute
`8416f1f`):

```
$ nix develop -c zig build bench -- --iters 1 --filter bjt      # 1m36s

fixture                    zp-cpu     zp-gpu    ngspice   cpu/ng
bjt/cascode                  skip       skip   15.51 ms        -   OpDidNotConverge
bjt/common_emitter       79.96 ms   79.83 ms    8.42 ms     0.1x
bjt/diff_amp                 skip       skip    8.81 ms        -   DcSweepSourceNotFound
```

Already fixed, do not re-investigate:

- `no libcall available for fexp` on the nvptx PTX step → `gompute.math`.
- gompute 1.0.0 panicking `docs/ is missing` for every consumer → `pkg_hash`
  guard, upstream.
- `dev_opt = .ReleaseSafe` costing 443 s on hisimhv_va → `.ReleaseFast`
  (`modules/devices/build.zig:212`).

---

## Thread 1 — `--gpu` never reaches a GPU  **[PROVEN]**

`zp-gpu` 79.83 ms vs `zp-cpu` 79.96 ms is not measurement noise; it is the same
code path. The flag is parsed and then discarded.

`src/main.zig:81` parses it, `src/main.zig:189` forwards it, and
`src/engine.zig:63`:

```zig
// Kept in the signature, unused for now: `config.gpu` drove the
// megakernel probe that used to live below. See the note at the
// `errdefer` further down — GPU moved to per-device kernels in
// modules/devices, which have not been wired to a launcher yet.
_ = config;
```

`grep -rn "RawKernel" src modules --include=*.zig` returns only a comment
(`modules/devices/src/engine.zig:20`). Nothing instantiates a kernel.

So: every device kernel this project compiles to PTX is **built and never
launched**. `engine.DeviceKernel` (`engine.zig:1412`) is the entry; `GpuSink`
(`engine.zig:1329`) is the scatter side; both are complete. What is missing is
host-side launch.

**Consequence for bench:** `zp-gpu` numbers currently published in
`benchmark/RESULTS.md` are CPU numbers. Worth checking whether that file makes
a GPU claim it cannot support.

**Where to start:** gompute's `RawKernel(entry_name, backend)`
(`src/host/raw.zig`) — as of 1.0.0 it shares one primary context and module per
device, so instantiating 37 of them is no longer the disaster it was. Kernel
symbol is `kernels.kernelName(name)` = `arp_eval_<name>`
(`modules/devices/src/kernels.zig:23`), re-exported via `root.zig:30`.

**Watch out:** only a subset of devices have kernels at all.
`engine.gpuEligible` (`engine.zig:1321`) is
`!PrepCache and !State and !history and !limit`, which excludes `hisim2_va`,
`vsource`, and the tline family. A launcher must fall back to CPU per device
type, not per run.

---

## Thread 2 — every param-driven analysis is dead  **[PROVEN root cause, fix unverified]**

`DcSweepSourceNotFound` is not a diff_amp problem. The chain:

1. `benchmark/fixtures/bjt/diff_amp/circuit.sp:13` — `.dc Vin -0.1 0.1 0.005`,
   and `Vin` is declared at line 5. The netlist is fine.
2. `modules/devices/models/vsource.va:73` — `parameter real dc = 0.0;`. The
   parameter exists and is named `dc`.
3. FastVAF lowers Verilog-A `real` to `f64`. Generated
   `vsource.zig:207` — `dc: f64 = 0.0,`.
4. `modules/devices/src/engine.zig:1249`:
   ```zig
   fn paramField(comptime T: type, comptime field: std.builtin.Type.StructField) bool {
       if (field.type != f32) return false;
   ```
5. No generated model field is `f32`, so `collectParams` appends **nothing**.
6. `modules/analysis/src/dc/dc.zig:66` — `const t = target orelse return error.DcSweepSourceNotFound;`

The `f32` filter is load-bearing for type correctness, not an accident:
`ParamRef.ptr` is `*f32` (`engine.zig:155`), so `.ptr = &@field(it, field.name)`
would not compile for an `f64` field. Both must change together.

**Blast radius — four analyses, all reading the same empty list:**

| caller | analysis |
|---|---|
| `modules/analysis/src/dc/dc.zig:58` | DC sweep |
| `modules/analysis/src/dc/dcmatch.zig:151` | DC match |
| `modules/analysis/src/sweep/sens.zig:198` | sensitivity |
| `modules/analysis/src/sweep/mc.zig:249` | Monte Carlo |

This reads like leftover state from before models became `f64` — `*f32` in a
double-precision solver is suspect on its own terms, independent of the bug.

**Proposed fix:** `ParamRef.ptr: *f64` and `paramField`'s test to `f64`. Then
check the `dflt > -1e30 and dflt < 1e30` sentinel test still means what it did,
and audit `ptr.*` writers for a silently-widening assignment.

**Verify with:** `nix develop -c zig build bench -- --iters 1 --filter bjt/diff_amp`.
A green diff_amp is necessary but not sufficient — `sens` and `mc` have their
own fixtures (`benchmark/fixtures/sens`, `benchmark/fixtures/ensemble`) and
should be run too, since they have presumably been silently no-oping.

**Unchecked:** whether those analyses currently *fail loudly* or silently
produce empty/garbage results. `dc.zig` errors; the other three were not read.
Worth knowing before assuming this is a fresh regression rather than a
long-standing one.

---

## Thread 3 — `bjt/cascode` fails to converge  **[OPEN]**

`OpDidNotConverge` on both CPU and GPU paths (same path, per thread 1).
Independent of thread 2 — cascode has no `.dc` line.

Nothing was investigated here. Genuinely unknown whether this is a model
problem, a gmin-stepping/continuation problem, or a bad fixture. Starting
points: `modules/analysis/src/dc/dc.zig:45` builds the converger options
(`gmin_extra`, `itl2`); ngspice solves the same netlist in 15.5 ms, so a
working reference exists to diff intermediate operating points against.

---

## Thread 4 — 10× slower than ngspice  **[LEAD]**

`bjt/common_emitter`: 79.96 ms vs ngspice 8.42 ms (`0.1x`).

Possible contributor, not yet quantified — the build emits **435** instances of:

```
warning[W0650]: unit is not provably finite, so it compiles in strict float
mode: unit 41 — I(qbd,gnd) — compiles with @setFloatMode(.strict)
  --> modules/devices/models/hisimhv_va.va:14355:9
```

Per FastVAF's own explanation (`modules/FastVAF/src/diag_code.zig:1685`):

> A unit that is proven finite compiles with `@setFloatMode(.optimized)` […]
> A unit that is not proven finite compiles with `@setFloatMode(.strict)`,
> where infinity is a legal, IEEE-defined value — correct, but measurably
> slower, **and it does not vectorize in the batch evaluator.**

"Does not vectorize in the batch evaluator" is the interesting half: the CPU
batch path is SIMD over instances, so a strict unit loses the vectorization the
whole design is built around.

**But do not assume this is the cause.** Two things to check first:

1. **The warnings quoted are for `hisimhv_va`, not `bjt`.** Whether the BJT
   model used by `common_emitter` has any strict units at all is unverified —
   check before optimizing anything.
2. The build runs `-Doptimize` at its default. Confirm the bench binary is a
   release build; a Debug `zpicey` would explain 10× on its own and make the
   float-mode question moot.

`diag_code.zig:1685` lists the concrete recoveries (parameter ranges,
`exclude 0`, `proof.Options{ .unknown_bound = 100.0 }`), and `--allow=W0650`
silences it if strict is genuinely wanted.

---

## Thread 5 — retire the `emitKernels` fork  **[design work, spec'd]**

`modules/devices/build.zig:198-291` is still a ~100-line copy of gompute's
`emitKernels`, forked only because 0.1.0 had no way to pass imports. 1.0.0 has
the API. Two wins the current one-line `ReleaseFast` fix does **not** deliver:

- **Model modules still enter device compilation at `-ODebug`.** They are
  created at `build.zig:74-90` with the *host* `optimize` and passed straight
  in; `dev_opt` reaches only the root module. gompute's `DeviceImportsFn` is
  called per backend with the device target and post-`deviceOptimize` mode, so
  this cannot happen by construction.
- **Per-model incremental rebuild.** One `KernelRoot` per model → one
  `build-obj` each, cached separately. Editing one `.va` rebuilds one object.
  This is the property the main loop actually needs.

Measured cost distribution (all 37 models, ReleaseFast, `nix/ptxbench.sh`):

```
serial total   37.4s emit + 16.1s ptx = 53.5s   (today: one TU, single-threaded)
per-model      wall clock ~= max(model) ~= 24s  (32 cores available)

hisimhv_va    18.0s emit + 5.5s ptx   140842 ll lines   37 MB ptx
bsimsoi_va     3.8      + 2.8          66568            11 MB
bsim4va        4.2      + 1.9          58902           8.5 MB
hicumL2_va     2.9      + 1.7          83992           9.5 MB
vbic13_4t      1.2      + 0.6          48290           3.2 MB
32 others     ~7 s combined
```

Those top four are the `heavy: true` roots; `heavy_lanes = 2` or `3` bounds
peak memory. gompute's doc example is literally this shape.

**Known obstacle, hit before starting:** per-model roots need
`modules/devices/src/engine.zig` promoted to a named module. Generated roots
live in a `WriteFiles` dir, so `@import("engine.zig")` will not resolve
relatively. Separately, `src/kernels.zig` owns `kernelName`, which
`src/root.zig:30` re-exports for host dispatch — that must stay put while the
generated per-model roots take over the `exportRaw` loop. Do not just move the
file.

Use `addKernels` rather than `emitKernels`: the devices build has no
`*Step.Compile` to hang artifacts on, and `addKernels` returns a private
`gompute` module (`Kernels.gompute`) to import at `build.zig:101` instead of
mutating the shared one.

---

## Tooling

`nix/ptxbench.sh` — times the two halves of the device pipeline separately
(`zig build-obj` IR emission vs `zig cc` IR→PTX) per model per optimize mode.
Produced every number in thread 5.

```sh
MODELS="bjt hisimhv_va" OPTS="ReleaseSafe/Debug ReleaseFast/ReleaseFast" \
  nix develop -c bash nix/ptxbench.sh
```

`OPTS` entries are `ROOT_OPT/MODULE_OPT`, because the real build sets them
independently (thread 5, first bullet).

**Two caveats before trusting it again:**

- Line 9 resolves gompute from `zig-pkg/gompute-*/src/device.zig` and will pick
  the stale `0.1.0` directory that is still sitting there. Point it at the
  1.0.0 package or delete the old one.
- It locates generated models by scanning `.zig-cache/o` for the *largest*
  matching `NAME.zig`. The cache holds several copies per model across build
  configs, some stale and truncated — an earlier version took the first match
  and silently benchmarked an 11-line stub. If a model reports ~6 `ll` lines,
  suspect the harness before concluding the model emits nothing (though for
  `hisim2_va`, `vsource` and the tlines, 6 lines is genuinely correct —
  `gpuEligible` excludes them).

---

## Not verified anywhere in this document

- **All HIP/AMDGCN claims are source-read only.** No AMD hardware on this
  machine, so `detectHipGpu` returns null and the HSACO path has never run
  here. It differs structurally from CUDA — `getEmittedBin()` + `ld.lld -shared`
  rather than IR → `zig cc`.
- The mixed root/module optimize A/B (thread 5, first bullet) was started twice
  and killed both times. The single-mode numbers are complete and measured; the
  mixed-config delta is inferred.
- Whether `sens`/`mc`/`dcmatch` fail loudly or silently under thread 2.
- Whether the bench binary is a release build (thread 4).
