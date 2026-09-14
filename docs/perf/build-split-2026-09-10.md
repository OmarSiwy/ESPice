# Per-model host objects — the build split

Closes docs/perf/remaining-2026-09-10.md §13 "Per-model LLVM objects".

Every generated device model now compiles to **its own object**, linked at the
end, instead of being a `-M` module inside the one `zig build-exe` that also
holds solvers, analysis and the app. A model that did not change is a cache
hit; the ones that did compile in parallel on all 32 cores.

Machine: 32 cores, Zig 0.16.0, `-OReleaseFast` (the default), `-Dgpu=true`
(the shipping configuration). ARPice at `spice-audit` tip `6aa1468`, VerA
`9dca44f`, gompute `04d7a76`.

## §13's "~35 minutes" was wrong — here is the real baseline

Three cases, each a paired sequential measurement on a warm cache:

| case | how it was provoked | before | after | |
|---|---|---|---|---|
| **a. one ARPice source file** | append a comment to `src/solvers/direct.zig` | **7:17** (437 s), 99% CPU | **2:36** (156 s), 101% CPU | **2.80×** |
| **b. one model's source** | append a comment to `src/devices/models/mos6.va` | **8:59** (539 s), 99% CPU | **3:55** (235 s), 232% CPU | **2.29×** |
| **c. all 38 models regenerate** | append a comment to every `models/*.va` | **10:20** (620 s), 110% CPU | **3:56** (236 s), 260% CPU | **2.63×** |

Peak build RSS on case (c): 1.86 GB → 839 MB.

§13 quoted ~35 minutes for case (c). On this tree it is **10:20**, and the
figure should not be quoted again without a re-measurement — VerA's generated
code has got cheaper to compile underneath this number more than once.

Two effects, separately:

- **Caching.** After the split, a one-file ARPice edit leaves exactly ONE
  uncached step in `zig build --summary all`: `compile exe espice`. All 38
  `dev_*` objects and all ~58 GPU kernel objects are cache hits. That is the
  whole of case (a)'s 2.8×; no parallelism is involved, the exe compile is
  still one serial LLVM invocation.
- **Parallelism.** Cases (b) and (c) are where the cores show up: average CPU
  utilisation goes 99% → 232% and 110% → 260%. Case (c) rebuilds 38 host
  objects, 38 regenerated sources and ~58 GPU kernel objects and still lands
  1 s away from case (b), which rebuilds one of each — the 38 objects fit
  inside the shadow of the serial exe compile.

### What the remaining 2:36 is

The exe still has to sema every generated model and codegen the *host-side
parameter binding* for it: `builder.applyKv`'s `inline for` over every
`D.Model` field (BSIMSOI declares ~1600), `setPolarity`, `setParam`,
`applySourceWaveform`. Those are typed reflection over struct layouts, not
device physics, and they are deliberately left alone — see "What was NOT
done".

Note on load: the box runs several agents. Case (a) re-measured later at
1:51 when the machine was quieter. The 2:36 above is the measurement taken
closest in time to its 7:17 baseline, which is the pairing that matters.

## Ir did not move

This was the stated risk: code moving into separate objects can lose
cross-module inlining, so the simulator gets slower while behaviour stays
identical. `valgrind --tool=callgrind --cache-sim=no --branch-sim=no`, total
program Ir:

| deck | before | after | |
|---|---|---|---|
| `scaling/parallel_inverters_100` | 433,933,973 | 433,975,425 | **+0.0096%** |
| `devices/mos6_inverter` | 146,648,882 | 146,673,920 | **+0.017%** |

+41 k and +25 k instructions — the extra is the `arp_device_*` getter call and
`vt.proto_add`/`vt.collapse`/`vt.derive` indirections, all of which run once
per device CARD at setup, not per eval.

The risk did not materialise because **the seam chosen was one that was
already a function pointer**. `Batch.eval` / `Batch.eval_newton` / `Hooks` are
a runtime vtable built by `ProtoStore(D).finalize` and stored in a
heap-allocated `Batch` array; nothing could inline through that before the
split either. Moving the code that sits behind those pointers into another
object changes which compilation unit emitted it and nothing else. The device
body itself is untouched — `D.eval` is still `@call(.always_inline)`'d into
`evalRange`, and `evalRange` is still monomorphised per device; it just
happens in `dev_mos6.o` now.

## Behaviour: bit-identical

- **Fixture suite: 286/286 decks bit-identical.** Every
  `benchmark/fixtures/**/circuit.sp` run under both binaries with `-b -r`, exit
  code and SHA-256 of the raw file compared. Zero differences.
- **GPU path bit-identical**: `--backend cuda` on `devices/mos6_inverter`,
  raw files `cmp`-equal. The scatter tapes, Model/Instance PODs, pattern CSC
  and plane layout are untouched; `cuda_blob_N`/`hip_blob_N` plumbing is not
  even adjacent to this change.
- **`ZP_MEM_STATS=1` rows identical**, including the per-device-type row
  names. That is not free — see `@typeName(D)` below.
- `zig build test`: **406/406**, matching the branch point. `test-devices`
  still trips the documented stderr gate (§13's last bullet): the binary
  passes 11/11 with exit 0 standalone, and the two warnings it prints come
  from `root.zig`'s own "unsupported LEVEL" test.
- `zig build -Dgpu=false` (the CPU-iteration build) still green.

## The design

`build.zig` compiles `src/devices/host_device.zig` once per model — the exact
mirror of what it already does with `src/devices/kernels.zig` for the GPU —
each time against the one-device `models` aggregate that already existed for
the kernel roots. Each object exports `arp_device_<stem>`, a getter for
`engine.deviceVtable(D, ...)`.

That vtable is **not new**. `DeviceVtable` is the runtime `.so` ABI
`loader.zig` already uses for `.hdl` cards: `init_model`, `set_model_param`,
`derive`, `collapse`, `proto_create`, `proto_add`. `Builder.addDynDevices` has
been driving devices through it for as long as the loader has existed. The
split reuses it verbatim for the builtins.

Three call sites change:

- `devices/root.zig` gains `modelName(D)` (catalog type → stem) and
  `vtable(stem)` (`@extern` on `arp_device_<stem>`).
- `Builder.addDevice` routes a *generated* device through
  `vt.collapse` + `dynProto` + `vt.proto_add`. The hand-written natives
  (`ltra_native`, `txl_native`, `coupled_ltra`) keep the typed path — they have
  no object and are small.
- `addSingleDevice`'s `D.derive(&model)` becomes `deriveModel(D, &model)`,
  which goes through `vt.derive` for generated devices. Same function, called
  through a pointer; calling `D.derive` directly would drag bsim4's derived-
  parameter pass back into the executable's own compilation.

Everything else in `builder.zig` is unchanged, because every caller already
went through `Builder.addDevice`.

### Why `@typeName(D)` and not the catalog stem as the vtable name

`Proto.type_name` is what `Circuit.freeze` hands `memstats.enter`, and
`--memstats` prints it. `ProtoStore(D).finalize` sets it from `@typeName(D)`;
handing `deviceVtable` the stem `"mos6"` would have renamed every device row
in that report. `host_device.zig` passes `@typeName(D)` so the text is the
text it always was.

### Deliberate omissions

- **No `arp_layout_hash` check across the boundary**, unlike `loadDevice`'s
  gate for dlopen'd devices. These objects come out of this build graph at the
  same target, optimize mode and strip setting, compiling the same generated
  source; the two sides cannot disagree without the build itself being broken.
  Upgrade path if that changes is the exported hash the `.so` path already has.
- **`anyerror` values cross the object boundary** (`proto_add`,
  `Proto.finalize` return `anyerror!T`) and Zig assigns the global error-set
  indices per compilation. This is the same contract the `.so` device path has
  always had; it can only surface as a wrong `@errorName` on an OOM path.
- Binary grew 29 MB → 32 MB. Object-granular linking keeps device paths the
  monolith could dead-code-eliminate.

## What was NOT done, and why

The exe's remaining per-device cost is `applyKv` and friends — comptime
reflection over `D.Model`/`D.Instance` fields. `DeviceVtable.set_model_param`
could replace it and take the executable to *zero* per-device codegen, but it
would **change parameter binding semantics**: `applyKv` carries the ngspice
IOPR alias table (`vt0|vto`, `cjo|cj0|cj`, …) and `set_model_param` does not.
That is a behaviour change wearing a build-infrastructure costume, and this
task's bar is "changes nothing observable". Left alone.

## Ported vs reimplemented: reimplemented

`../espice-buildsplit` is gone (`git worktree list` calls it prunable); the
work survives only as branch `buildsplit`, commit `bc05efa`, on base
`1d4dfa1` — 28 commits behind `spice-audit` and predating memstats, the
limiting rework, AC excitation, the dedup delete and `jac_rows`.

It was not rebased, and the base drift is the smaller of the two reasons. The
larger one is the **seam**: `bc05efa` exports the scalar-instantiated
`espice_{eval,q,evalq,evalprep,qprep}_<stem>` with C callconv and calls them
from `evalRange` through `@extern` trampolines. That puts a new
non-inlinable C call **inside the per-instance eval loop**, which is precisely
the regression this task says must be surfaced rather than shipped quietly —
its own commit message concedes the trivial devices had to be excluded for
that reason, leaving a hand-maintained 22-stem `precompiled_stems` list and a
three-way comptime gate (root marker via `build_options`, `zig_backend ==
.stage2_llvm`, `!gompute.is_device`) spread over 166 lines of `engine.zig`.

The vtable seam needs none of that: it is already a function pointer, so it
covers **all 38 models with no list**, adds nothing to the hot loop, and
`engine.zig` is not touched at all. The numbers agree — `bc05efa` reports
213→179 s for a solver-file edit (1.19×) and 247→182 s for a bsim4va edit
(1.36×); this is 437→156 s (2.80×) and 539→235 s (2.29×).

Nothing was ported. `bc05efa`'s one reusable idea — that an object and the exe
compiling the same source at the same target agree on layout by construction —
is noted above as the reason the layout-hash gate is skipped.

## Reproducing

```
# baseline / after, case (a)
printf '\n// probe\n' >> src/solvers/direct.zig && time zig build

# case (b)
printf '\n// probe\n' >> src/devices/models/mos6.va && time zig build

# case (c)
for f in src/devices/models/*.va; do printf '\n// probe\n' >> "$f"; done
/usr/bin/time -v zig build

# Ir
valgrind --tool=callgrind --cache-sim=no --branch-sim=no \
  --callgrind-out-file=/dev/null zig-out/bin/espice -b -r /tmp/o.raw \
  benchmark/fixtures/scaling/parallel_inverters_100/circuit.sp

# fixture bit-identity (needs a reference binary from the previous build.zig)
find benchmark/fixtures -name circuit.sp | sort | while read -r sp; do
  "$BIN" -b -r /tmp/r.raw "$sp" >/dev/null 2>&1
  echo "$? $(sha256sum /tmp/r.raw | cut -c1-16) $sp"
done
```

A model-source probe is a real rebuild even though the comment does not reach
the generated Zig: vera's output lands in a new content-addressed cache path,
and the path is part of the module definition the exe compilation hashes.
