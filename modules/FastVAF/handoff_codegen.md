# Handoff — codegen & frontend performance research

Status as of 2026-07-27. Everything below was **measured**, not estimated; where a
number came from a subagent rather than a direct re-run it says so. Dead ends are
recorded on purpose — three of them looked obviously right and were wrong.

---

## 1. Skills used, and what each actually bought

Five skills drove this. Recording them because each one changed a decision, and
the next round should apply the same lenses.

| Skill | What it contributed here |
|---|---|
| **data-oriented-design** | The one real win. Its rule *"replace `HashMap<EntityId, Component>` with a dense packed array"* is exactly what `ssa.zig`'s `defs` needed. Its checklist question *"no field wider than its max value"* also correctly told us to **stop** — see §5.2. |
| **simd-loops** | Its **triage-before-code** step is what prevented a correctness bug. Classifying each loop as none / accumulator / **chain** killed most candidates before a line was written, and the "verify against a retained scalar version" step is what caught the bad `stamp()` vectorization. |
| **design-patterns** | Lowest yield. The codebase was already well-factored; the audit's "extract this 686-line switch" findings were declined as churn with no measured benefit. |
| **caveman** | Prose style only. No engineering effect. |
| **zig-gpu-kernel-engineering** | Framed the emitted-code work: a 60k-line function is a register-pressure and occupancy disaster, and its "hardware does not change because the language did" framing is why we chased *function shape* rather than micro-optimising expressions. |

**The meta-lesson, which matters more than any of them:** the engine was *already*
data-oriented (SoA `MultiArrayList`, `enum(u32)` handles, arena-per-compilation,
hot/cold column splits). A blanket "apply the skills to every file" refactor would
have been pure churn. Every real win came from **measuring first** — callgrind, then
`@sizeOf`/density instrumentation, then LOC histograms of the emitted text.

---

## 2. What changed

### 2.1 `ssa.zig` — `defs` hash map → dense matrix

`defs` was `HashMap<u64 = (place<<32|block), Value>`, documented as *"sparse because
most (place,block) pairs are undefined."* **That claim was false.** Instrumented on
`hisimhv_va`:

```
places = 1,978   blocks = 5,646
live defs = 2,114,902   of   1978 × 5646 = 11,167,788 cells   →  19% dense
hash capacity = 4,194,304 slots × 13 B ≈ 54 MB  (already > the 45 MB full matrix)
```

Small modules measured at ~100% density (34 of 35 cells, 30 of 36, 8 of 8).
Callgrind put hashing/probing/rehashing at ~35% of frontend runtime, `grow` alone at
9.2%. Replaced with a dense **place-major** matrix, `absent = maxInt(u32)` sentinel.

| model | frontend time | peak RSS |
|---|---|---|
| hisimhv_va | 0.41 → **0.28 s** (1.46×) | 338 → 362 MB (0.93×) |
| bsim4va | 0.33 → **0.20 s** (1.65×) | 286 → 246 MB (1.16×) |
| hisim2_va | 0.17 → **0.13 s** (1.30×) | 143 → 155 MB (0.92×) |
| bsimsoi_va | 0.15 → **0.12 s** (1.25×) | 143 → 155 MB (0.92×) |

Memory is a **wash to ~8% worse** — power-of-two stride rounding means 1978 × 5646
live cells occupy 2048 × 8192 = 67 MB vs the hash map's 54 MB. That trade was taken
deliberately for the speed. Codegen output stayed **byte-identical on all four
foundry models**, which is the strongest evidence the refactor preserved semantics.

### 2.2 `codegen.zig` — two real bugs in the emitted code

Neither was on the task list; both were found while investigating something else.

1. **A filter inside a contribution emitted a device that would not compile.**
   `emitOperator`'s `.laplace` branch never set `uses_model`, so `emitUnit`'s
   back-patch renamed the parameter to `_` while the body still called
   `__sec(model)` → `error: use of undeclared identifier 'model'`. Reproduced
   independently on the pre-fix binary. Every existing filter fixture dodged it
   (fixture 066 only feeds the filter to `$strobe`, so it never lands in the core).

2. **The §9.4 display unit emitted `c.f*` with no `const c`.** `zig build
   exhaustive` was silently **41/44**; it is now **44/44**. Found only because
   fix #1 unmasked it.

### 2.3 `eval_batch.zig` — one loop vectorized, one deliberately not

`gatherVolts` vectorized via a `gatherInto` helper in the skill's
splat/chunk/lane-op/tail shape: **1.72×** on that loop, ~2% end-to-end (it is only
~5% of an iteration). Worth doing because LLVM will *never* autovectorize it — it
must assume `node_v` and `b.volts` alias, and the scalar loop emits zero
`vgather*`. (Subagent-measured.)

### 2.4 `codegen.zig` — emitted LOC −26%

The emitted device was **one 60,050-line function** = 97.7% of a 61,482-line file.
20,208 lines were bare `var tN: S = undefined;` hoisted to function scope by
`emitUnitBody`, each paired with a later `tN = <expr>;`. Scope-containment analysis
over the emitted text:

```
20,208  hoisted `var … = undefined;`
 16,022   single-assignment, ALL uses inside the defining block → `const tN = expr;` at the def
  1,179   single-assignment but uses ESCAPE the block           → must stay hoisted
  2,718   assigned 2+ times (genuine phi)                       → must stay hoisted
    289   never assigned (dead)                                 → deleted
```

Implemented as a **dry emission pass** (`probeBody`) that records per-slot
`def_off / max_use / scope`, rewinds, then hoists only what fails containment. A dry
run rather than a dominator query because the emitted brace nesting is *not* the CFG
— `planDeadBranches` deletes `if`s, the peephole deletes labels, `emitEdge` inlines
subtrees — so re-deriving it would be a second, subtly different copy of the emitter.

| model | LOC | zig type-check | NVPTX-target analysis |
|---|---|---|---|
| hisimhv_va | 61,482 → **45,240** (−26.4%) | 2.02 → **0.67 s** (3.0×) | 2.29 → **0.66 s** (3.5×) |
| bsim4va | 28,409 → **21,621** (−23.8%) | 0.52 → **0.14 s** (3.8×) | |
| hisim2_va | 44,540 → **32,630** (−26.7%) | 1.11 → **0.33 s** (3.4×) | |
| bsimsoi_va | 23,348 → **16,587** (−28.9%) | 0.39 → **0.12 s** (3.3×) | |

All 38 models: 212,471 → 157,142 lines (−26.0%). **Compile time improves more than
LOC does** — removing 16k mutable function-scope locals removes a superlinear cost
in semantic analysis, not just lines to parse.

**Correctness carve-out that must survive any future edit here:** a slot the function
*returns* cannot be seeded `undefined`, because the return is reached from exit
blocks the definition does not dominate. Those are seeded with zero. Pinned by
`tests/fixtures/exhaustive/069_conditional_operator_state.va`. See the comment at
`codegen.zig` `emitUnitBody`.

---

## 3. Verification gates — all four must stay green

```bash
zig build test         # exit 0 AND "conformance: 856/856 fixtures pass, 0 fail"
zig build exhaustive   # exit 0 AND "exhaustive: 44/44 transcripts match, 0 fail"
```

`exhaustive` is the **numerical** gate — it is the one that proves device behaviour
did not change. It was silently 41/44 before this round; if it drops, something broke.

For frontend/IR changes, also diff generated output against the four foundry models
in `../../modules/devices/models/`. **Byte-identical output is the strongest
available signal** that a refactor preserved semantics:

```bash
for m in hisimhv_va bsim4va hisim2_va bsimsoi_va; do
  ./fastvaf --emit-zig -o /tmp/new_$m.zig ../../modules/devices/models/$m.va
  cmp /tmp/base_$m.zig /tmp/new_$m.zig && echo "$m IDENTICAL"
done
```

(For *codegen* changes the output is meant to change, so this gate does not apply —
lean on `exhaustive` instead.)

---

## 4. Build & measurement recipes

**Do not run `zig build -Doptimize=ReleaseFast`.** `build.zig` builds one test
binary per src file (17) plus the CLI, and the install step depends on all of them.
That is ~9 minutes at ReleaseFast. Build the CLI alone:

```bash
zig build-exe src/main.zig -OReleaseFast -femit-bin=/tmp/fv \
  --cache-dir .zig-cache --global-cache-dir /home/omare/.cache/zig     # ~45 s
```

**Do not time rebuilds with `touch`.** Zig's cache is content-addressed, not
mtime-based, so `touch x.zig; time zig build` measures cache validation and reports a
fake ~2 s. This produced a wrong "71 s vs 2 s" figure during this session before it
was caught. Change real bytes.

Emitted-device compile time (use a **fresh cache dir per run**):

```bash
C=$(realpath ../../modules/devices/src/contract.zig)
zig build-obj -fno-emit-bin --dep contract -Mroot=<dev>.zig -Mcontract=$C --cache-dir /tmp/tc1
# GPU path:
zig build-obj -OReleaseFast -target nvptx64-cuda-none -mcpu sm_89 \
  --dep contract -Mroot=<dev>.zig -Mcontract=$C --cache-dir /tmp/ptx1 -fno-emit-bin
```

Profiling: `perf` is absent on this box; `valgrind --tool=callgrind` +
`callgrind_annotate` works and is what found the SSA hot spot.

---

## 5. Dead ends — do NOT retry these

### 5.1 SSA matrix layout alternatives (both measured, both worse)

- **Grow the block axis to `mir.blockCount()` instead of doubling.** Re-strides more
  often, and a re-stride transiently holds the old *and* new buffer → peak RSS went
  **up** (hisim2_va 155 → 194 MB).
- **Block-major with rows appended exactly (`new_cap = b + 1`).** One realloc+copy per
  block, 5,646 of them = quadratic. **4.6 GB RSS and 4× slower.**

Both are recorded in the `defs` doc comment in `ssa.zig`.

### 5.2 Shrinking struct fields / packing bools

Dropped on measurement, not on principle. `ParamInfo` padding × ~500 params = 3.5 KB;
`Macro`/`Cond` bools × ~100 = ~100 B; `Contribution.noise_kind` × ~200 = 1.4 KB.
**Under 5 KB total against a 340 MB process.** These are AoS side tables read once at
declaration time, not hot loops. For the emitted `Instance` bools the saving is
literally **zero bytes** — Zig already packs them into padding beside
`analysis_kind: u8`, `@sizeOf(Instance)` is 48 either way (subagent-measured across
all 38 models).

### 5.3 MultiArrayList "padding holes"

An audit claimed `ast.Node` and `mir.InstRow` waste 3 bytes of padding each and that
fields should be reordered to "cluster hot columns". **Both false.** These are
`MultiArrayList` rows — each field is its own tight array, there is no per-row
padding, and field order does not affect adjacency of element *i* across columns.
`mir.zig` already documents this correctly at the `tok` field.

### 5.4 Vectorizing `eval_batch.stamp()`

An audit claimed `stamp_idx` entries are non-aliasing and the loop vectorizes.
**Wrong, three ways:** every terminal touching ground maps to one shared sink cell
(by design, documented in-file); two instances bridging the same node pair share a
CSR slot (which is *why* the operator is `+=`); and `resid_idx` *is* the node index.
A built-and-measured vectorized version produced **14 silently-wrong CSR cells at up
to 14% relative error** on a 100k-instance netlist — and was **not even faster**
(3.05 ms vs 3.04 ms; it is memory-latency-bound, not ALU-bound). The existing test
would not have caught it: its fixture assigns `stamp_idx[e*np+i] = e*n_inst+i`, unique
by construction. A `DO NOT VECTORIZE` note is now in the `stamp` doc comment.

### 5.5 The gompute "less LOC for codegen" premise

Investigated at gompute `ae91c705` (which is current — remote HEAD equals the pinned
hash in `modules/devices/build.zig.zon`). The new ops (`mapTo`, `zip`, `mapIndexed`,
`reduce`, `gather`, `scatter`, `Fused`) **do not reduce codegen LOC**, because:

- `codegen.zig` emits **zero** gompute/kernel code; GPU wrapping lives in
  `modules/devices/src/kernels.zig`, already **37 lines** (a comptime loop over the
  model catalog calling `gompute.exportRaw`).
- The kernel body `engine.DeviceKernel` is **33 lines**: a *raw* kernel, one thread
  per instance, 10 `GlobalPtr` args, calling `evalRange` through a `GpuSink`.
- The new ops are elementwise/reduction primitives over flat buffers and cannot
  express a per-instance residual+Jacobian that scatters into CSR **with aliasing**
  (same aliasing as §5.4).

The new ops are still the right tool for genuinely elementwise device work — they
just do not fit *this* kernel.

---

## 6. Open leads, strongest first

### 6.1 Split the single huge core function (highest value)

`modules/devices/build.zig` records the smoking gun:

> *"on these single-huge-eval-function models something in LLVM goes superlinear on
> the safety-check CFG — measured **443 s vs 13.6 s** for hisimhv_va"*

The −26% LOC cut attacked this and won 3.5× on NVPTX *semantic analysis*, but that
measurement used `-fno-emit-bin`. **The 443 s lives in LLVM codegen, which was not
measured.** Next step: A/B a full NVPTX emit (drop `-fno-emit-bin`) before/after, then
consider splitting the core into several functions. Watch for: splitting adds
call overhead and may defeat cross-expression CSE, so gate it on the numerical
`exhaustive` suite plus a runtime benchmark, not just compile time.

### 6.2 The remaining hoisted temps

`hisimhv_va` still has ~4,024 function-scope `var`s: ~2,803 genuine multi-assignment
phis and ~1,221 single-assignment escapers (subagent-measured). The escapers are the
labelled-block reconstruction case. Reducing them means changing the *block structure*
the emitter produces, not the declaration strategy — a bigger and riskier change.

### 6.3 SSA memory

The dense matrix is ~8% worse on peak RSS than the hash map (§2.1). The waste is
power-of-two stride rounding, and both obvious fixes are dead ends (§5.1). A real fix
would attack the *cause*: 2.1 M live defs for only 1,978 variables, because
`readVariableRecursive` memoizes at every block in a single-predecessor chain. Merging
straight-line blocks during lowering would collapse both block count and def count —
but that changes lowering, not SSA.

### 6.4 Frontend, post-SSA

Re-profile with callgrind. Before this round SSA was ~55% of the frontend; with that
removed, `proof.Prover.walkBlock` (~11% before) is likely the new top. Note the
lexer/preprocessor byte loops are **not** SIMD candidates — they were triaged as
genuine state-machine chains (string/comment/conditional state), which the
simd-loops skill explicitly says to report and stop on.

---

## 7. Repo state warning

`src/*.zig` in this module is largely **untracked** (`git status` shows `??`), as is a
larger in-flight restructure. Everything in this document is uncommitted at time of
writing. **Never `git stash` here** — it will drop untracked work. Commit instead.
For the same reason, do not give subagents git-worktree isolation: a worktree contains
only committed files and would miss the live source. Partition agents by **file
ownership** instead (this round ran three agents concurrently that way, on
`eval_batch.zig` / `codegen.zig` / disjoint sets, with no conflicts).
