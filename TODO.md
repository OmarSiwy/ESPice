# TODO — emitted-LOC and SIMD work

Status 2026-07-27. Every number here was **measured**, not estimated. Dead ends
are recorded on purpose; two of them looked obviously right.

---

## Done, gated, uncommitted

Gates for all of it: `zig build exhaustive` → 44/44, `zig build test` → 470/472
(see "Gate baseline" below), emitted output byte-identical on all 38 models for
the frontend change.

| | session start | now |
| --- | --- | --- |
| `hisimhv_va` emitted LOC | 45,240 | **32,075** (−29.1%) |
| all 38 models | 157,142 | **113,515** |
| zig type-check (`hisimhv_va`) | 0.65 s | **0.27 s** (2.4×) |
| frontend instructions | — | **−9.2%** |
| frontend peak RSS | 361 MB | **270 MB** |

Against the pre-round baseline of 61,482 lines that is **−47.8%**.

### 1. `ssa.zig` — `defs` matrix is mapped, not allocated-and-zeroed

`memset` was the **top of the frontend profile — 13.5% of all instructions on
`bsimsoi_va`**, 100% of it under `writeVariable → defsIndex`, because `absent`
was `maxInt(u32)` so every stride doubling zeroed the whole new buffer before
copying the old rows back over half of it.

Cells now hold `@intFromEnum(value) + 1` so **`absent` is 0**, and the matrix
comes from `std.heap.PageAllocator.map` — a fresh OS mapping is zero-filled, and
those zeros *are* the memset.

- `std.heap.page_allocator` does **NOT** work: the `Allocator` interface
  `@memset`s fresh bytes to `undefined` (0xAA) under runtime safety, so the
  zeros only survive in ReleaseFast. 67 tests aborted on the canary in
  `mapZeroed`, which is exactly why the canary is there.
- Lazy faulting is the second half of the win: untouched cells never become
  resident, so peak RSS is now **below the hash map the dense matrix replaced**
  (338/286/143/143 → 270/201/113/108), not merely back to par.
- Side effect: the pre-fix binary **cannot be profiled on `hisimhv_va`** — it
  OOMs under valgrind. The post-fix one does not.

### 2. `codegen.zig` — single-use fusion (−20.3%)

Measured on the emitted text *before* writing anything: of 16,242 `const tN`
temps, **14,930 (92%) are used exactly once**, 11,366 of those on the very next
line. A value used once, by the very next statement of its own block, is now
rendered inside that statement.

No new rendering path was needed — `renderValueRef` already falls through to
`renderInst` for anything without a slot, so clearing the slot IS the fusion,
and chains collapse transitively because the fallthrough recurses.

Why adjacency and not "def dominates use": one use means no duplicated work
(`eager_use == 1 and arm_use == 0`; an arm use is re-rendered per arm by
design), and *next statement* means the computation moves later by exactly one
statement inside the same block — nothing can be hoisted into a loop body or
sunk past a side effect. It must NOT call `reattribute`; operands stay eager.

### 3. `codegen.zig` — hoists share one array per type (−11%)

The ~4 k surviving function-scope `var tN` became `var h: [n]S` (plus `hi`/`hs`).

**Free at runtime, measured not assumed.** Every index is compile-time constant,
so SROA splits the aggregate back into registers: on the full NVPTX kernel the
array version emits the **same 921,478-line PTX, the same 6 `.local` decls, the
same 4.70 s of PTX codegen**, and the largest alloca surviving LLVM is 248 B —
one `Dual(32)`, not the 870 KB the array would occupy as memory. Do **not**
"fix" this into a `static`/global array: on the GPU that is shared across
threads.

Two bugs, both caught by the gates, both worth remembering:

1. `hoist_idx` must be cleared at the **top** of `emitUnitBody`. Slot numbering
   is unit-local, and both the straight-line early return and `probeBody`'s dry
   run emit slot names before the real assignment — so clearing later let the
   previous unit's indices rename this unit's slots. `exhaustive` caught it.
2. The returned-slot carve-out changed shape: one array is declared `undefined`
   as a whole, so the guarantee is no longer per-declaration. It is now "the
   array is exactly as long as the number of zero-seed stores", and the test in
   `codegen.zig` asserts **both** halves. Assert both or it is not tested.

---

## Next: if-conversion (`src/FastVAF/ifconv.zig`, untracked)

Detection is **written and sized**; the transform is **not written**. The file is
scan-only and is not wired into the pipeline.

```
hisimhv_va  445 branches, 271 convertible (61%) | rejected: shape=131 impure=43 escapes=0 merge_shared=0
bsim4va     412            176 (43%)
hisim2_va   275            166 (60%)
bsimsoi_va  216            127 (59%)
```

Zero escapes and zero shared merges on all four — the preconditions are cheap to
satisfy in practice. Each MIR branch is re-emitted by ~3.3 units on average
(1,448 emitted `if` blocks from 445 MIR branches), so converting 271 should be
worth **~4,400 lines**, another ~14%.

**This is if-conversion, NOT predication, and the distinction is the whole
design.** §4.2.12 requires the value-form conditional to stay lazy, and
`codegen.renderInst` carries a comment forbidding "a select of two pre-computed
values" because `x > 0 ? ln(x) : 0` would then run `ln(x)` with x ≤ 0 — UB under
`@setFloatMode(.optimized)`. This pass rewrites the diamond into a MIR `select`,
which codegen renders as a Zig `if` **expression** — still lazy. The existing
use-counting is what enforces it: a value used only in a select arm scores
`arm_use`, never `eager_use`, and the inline sweep renders it inside the arm.
That is why the precondition "every value an arm defines is used only by the
merge's phis" is load-bearing, not a nicety. It also *helps* `proof.zig`, which
already treats a select condition as a guard scoped to its arms.

Remaining work, in order:

1. `insertBeforeTerm` in `mir.zig` — the one missing primitive. Emitted
   statement order comes from the intrusive `first`/`next` chain, and `addInst`
   appends **after** the terminator.
2. Per merge phi: emit `select(cond, then_val, else_val)` into X, then
   `setAlias(phi, select)` — the same mechanism trivial-phi removal uses.
3. Rewrite X's terminator `branch` → `jump(merge)`. The arms become unreachable
   and need no statements, because every arm value is arm-only and gets inlined.
4. Iterate to fixpoint for nested diamonds.
5. Wire into `root.zig` between lowering and `proof.proveOpts`, and delete the
   scan-only entry point or keep it behind a test.

---

## Later

### Instance-lane SIMD — the runtime exists, nothing emits it

`eval_batch.zig` (lines ~55–80) specifies a device contract that **codegen has
never emitted**:

```zig
pub fn region(comptime N: usize, v: *const [n_terminals]@Vector(N, f64), ...) @Vector(N, u8);
pub fn eval(comptime N: usize, comptime r: u8, v, p, c,
            resid: *[n_terminals]@Vector(N, f64),
            jac:   *[n_terminals*n_terminals]@Vector(N, f64)) void;
```

SoA batch, region bucketing so each bucket is straight-line, `@select` instead of
branches. `eval_batch.zig` is exported and tested against **zero real devices**.
Emitted devices instead expose `pub fn eval(comptime S: type, x: [n_u]S, ...)`.

Note the eval is **already SIMD on a different axis**: `engine.zig:491`
instantiates `S = Dual(n_u)`, and for `hisimhv_va` **n_u = 32**, so every emitted
`.mul`/`.add` is already a `@Vector(32, f64)` op on the derivative part — 264 B
per temp. That is also why one huge function is a register-pressure disaster.
Moving to instance lanes means dropping `Dual` and emitting the derivative chain
explicitly, since the contract asks for `jac` directly. If-conversion above is
the prerequisite, because that contract wants `@select`, not branches.

### Remaining hoisted temps

After fusion + arrays, `hisimhv_va` still has 6,826 assignments to hoisted slots.
Those are genuine phis; reducing them means changing the **block structure** the
emitter produces, which is what if-conversion starts on.

---

## Gate baseline — read before believing a red build

`zig build test` **exits 1 on a pre-existing failure**, verified by re-running
the same suite with a stock `ssa.zig`: 470/472, both failures
`analyses.test.disto` (`diode circuit produces nonzero HD2`, `HD2 scales
linearly with amplitude`). Unrelated to the frontend — the generated devices are
byte-identical. Treat **470/472 with exactly those two** as green, and diff the
failure list rather than the exit code.

`zig build exhaustive` → **44/44** is the numerical gate and must stay exact.

Recipes (build the CLI alone; the full `-Doptimize=ReleaseFast` builds 18
binaries, ~9 min):

```bash
zig build-exe src/FastVAF/main.zig -OReleaseFast -femit-bin=/tmp/fv \
  --cache-dir .zig-cache --global-cache-dir /home/omare/.cache/zig     # ~45 s
```

Do **not** time rebuilds with `touch` — Zig's cache is content-addressed, so it
measures cache validation and reports a fake ~2 s.

---

## Dead ends — do NOT retry

### Splitting the huge core function

The `build.zig` comment cites **443 s vs 13.6 s** for `hisimhv_va` and it was the
top-ranked lead. Measured, there is nothing there: that number was **ReleaseSafe**,
and `dev_opt` has pinned device code to ReleaseFast since.

| stage | 45,240 lines | 61,482 lines |
| --- | --- | --- |
| `build-obj -femit-llvm-ir` (sema + LLVM opt) | **6.9 s** | 11.9 s |
| `zig cc -S` — actual PTX codegen | **4.67 s** | 4.70 s |

The LOC cut is worth 1.72× on the first stage and **exactly nothing** on the
second — after LLVM's optimizer both are the same program (7.8 MB IR, 37 MB PTX
either way, differing only in symbol prefixes). Whole pipeline ~12 s.

Two traps when reproducing: `-femit-asm` fails with `NVPTX aliasee must be a
non-kernel function definition` (the real build goes IR → `kernel_ir_tool` →
`zig cc`), and the device root **alone** compiles in 0.65 s to a 15 KB stub
because the eval fn is generic over `S` and nothing instantiates it until
`kernels.zig` names it. Timing the device file by itself measures nothing.

### Blanket predication of the emitted control flow

12,930 lines (36%) of the emitted file is brace/`break`/label/`if`/`continue`
scaffolding, which looks like the biggest single target. It is not directly
attackable: only **2% of the lines inside `if` blocks** sit in blocks free of
partial ops (`div`/`log`/`sqrt`/`pow`), so predicating would evaluate guarded
partial ops unconditionally. Use if-conversion to `select` instead, which keeps
the arms lazy — see above.

### Verilator-style "one template + N data blobs"

Measured, viable, and **rejected on purpose** — keep the straight-line shape.
A tape + comptime `inline for` template at 16,000 ops: **20 lines of Zig + 16,002
lines of data, sema 0.34 s vs 0.22 s straight-line**. So comptime costs ~1.5×,
not the 100× that would have killed it outright, and the emitted `.zig` collapses
to nothing. The aggregate-index shape it forces is also proven safe (see item 3
above). It was dropped as a design preference, not a measurement — if it is ever
revisited, those are the numbers.

Note Verilator does not actually work this way for logic: `.mem` is `$readmemh`
memory *contents*, and the logic is still generated C++ per module.
