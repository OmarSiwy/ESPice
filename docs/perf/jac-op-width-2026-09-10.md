# f64 for the operating point, f32 for the transient — built, measured, off

2026-09-10, branch ARPice `jac-op-width`, on top of `6f60612`. ARPice-only;
`../VerA` untouched.

`docs/perf/jac-width-2026-09-10.md` §6 closed by saying the width is now a
call-site argument, so `DeviceBatch.evalInner` could take f64 for the operating
point and f32 for the transient — "one `if` in one function", not built. This
is that `if`, built and measured.

**Result: the split does exactly what §6 predicted on the OP side and nothing
on the other. `ngspice/mosmem` keeps its 50-iterate plain-Newton OP instead of
paying 11 gmin rungs and 144 iterates, and `convergence/mos_latch_ladder` keeps
3/3 plain. But the transient win the split was supposed to bank is gone: since
`rank4-collapse`, mos1/mos6 evaluate on a rank-4 basis where `@Vector(4, f64)`
is already one ymm, so f32 halves no register and only adds converts. The f32
transient now COSTS `parallel_inverters_100` +0.68% and `devices/mos6_inverter`
+1.75% Ir at unchanged iteration counts, and the full-f32 build that
`jac-f32-2026-09-10.md` measured at −6.38% / −5.1% reads +16.8% / +20.7% on
today's tip. There is nothing left to trade for, so the switch ships compiled
out (`engine.op_tran_split = false`), the CPU default stays f64, and the
recommendation is not to revisit it until a permitted device has a basis wider
than 4. 258/258 raws byte-identical, 288/288 exits, `zig build test` 414/414.**

---

## 1. The seam

The phase, not a new flag. `Circuit.setSimState` already publishes the analysis
kind to every batch before the pass it describes, and every Newton loop in the
tree that is not the transient publishes something other than `.tran`
(`op.solve`/`solveLadder` → `.dc` or `.ic`, `dc.zig` → `.dc`, the uic path →
`.ic`). So the batch learns its phase from the hook it already has:

```zig
fn setSimState(ctx: *anyopaque, st: SimState) void {
    ...
    if (comptime splittable) self.tran_f32 = st.kind == .tran and tranJacF32();
```

and `evalInner` picks the width off that one bool:

```zig
if (comptime splittable) {
    if (self.tran_f32) return @call(.always_inline, evalWidth, .{ self, tranJacFloat(D), ... });
}
@call(.always_inline, evalWidth, .{ self, jacFloat(D), ... });
```

`evalWidth` is the old `evalInner` body — the `narrowable` clamp and its two
`evalRange` calls — lifted to take the float width as a parameter, so the
narrow/wide *basis* split and the f64/f32 *width* split compose instead of
producing four hand-written call sites. `always_inline` for the reason
`evalQOnly` documents: letting it go out of line is a measurable Ir change for
identical work.

`tranJacFloat` is deliberately `gpuJacFloat` — the permission, read at a third
call site. A host order implies the permission (`jac_f32_host` ⇒ `jac_f32`), so
"the widest this device may be" already had exactly one spelling and the split
needed no new decl, no VerA change and no new build flag.

Three things did NOT have to move, checked rather than assumed:
`DeviceKernel.run` (still `gpuJacFloat`, still 13 arguments), `layoutHash` /
`abi_version = 7` (`Batch`/`Hooks`/`Planes` unchanged — `tran_f32` is a field
of the private `DeviceBatch(D)`, which the hash does not contain), and the
scatter tapes / PODs / pattern CSC / `[]f64` planes.

### 1.1 Nothing carries state across the width boundary

The concern is real and the answer is structural: **the residual half is
width-invariant.** `Dual.v` is `f64` unconditionally and every boundary of the
S protocol is f64 (`engine.test."Dual: an f32 Jacobian leaves the residual
bit-identical"` pins it), so `F` reaches the derivative vector and nothing
else. Everything the OP hands the transient is residual-side: `x`,
`Circuit`'s `[]f64` planes, `q_hist` (seeded by the deliberately
non-`setSimState`-preceded `ckt.eval(x, 0)` at `tran.zig:408`, i.e. still under
the OP's f64), the `q_tape`, `lim_x`, `computeBaseline`'s constant
contributions. The transient's first step therefore starts from the byte-exact
point the f64 OP converged to; only the matrix entries it linearizes with are
narrower.

Measured confirmation: under the split every transient on the three decks below
keeps the f64 build's accepted/attempts/`nr_iters` and `avg_dt` to the digit
(§2, §3). An inconsistent handoff shows up first as a rejected first step, and
there is none.

## 2. The discriminators

Both decks, three arms. `f64` is today's default; `split` is the same binary
with `op_tran_split = true` and `ESPICE_JAC_TRAN_F32=1`; `f32` is
`-Djac-f32=mos1,mos6`, the build `jac-f32-2026-09-10.md` was measured on.
`ZP_OPDBG=1`, OP iterates = total `newton it=` lines minus the transient's
`nr_iters`.

### 2.1 `ngspice/mosmem` (`.tran 20ns 2us`) — the +13.7% deck

| arm | `ladder: plain` | `plain conv=true` | gmin rungs | OP iterates | accepted / attempts / `nr_iters` |
|---|---:|---:|---:|---:|---|
| f64 (default) | 1 | **1** | **0** | **50** | 147 / 157 / 330 |
| **split** | 1 | **1** | **0** | **50** | **147 / 157 / 330** |
| f32 | 1 | **0** | **11** | **144** | 150 / 160 / 337 |

The split reproduces the f64 OP exactly — same 50 iterates, plain Newton holds,
no ladder — and the f32 row reproduces `jac-width-2026-09-10.md` §6's recorded
50 → 144. **The fall-through is removed.**

### 2.2 `convergence/mos_latch_ladder` — and why it cannot answer this question

| arm | `ladder: plain` | `plain conv=true` | gmin rungs | OP iterates |
|---|---:|---:|---:|---:|
| f64 (default) | 3 | **3** | 0 | 360 |
| **split** | 3 | **3** | 0 | 360 |
| f32 | 3 | **1** | **22** | 547 |

Green, and green for a trivial reason: **the deck is a `.dc` sweep with no
transient at all**, so under the split it is f64 everywhere and its raw is
byte-identical to the default's. It is evidence that the split does not damage
a DC solve, and nothing more. The 3 / 1 / 22 signature in row 3 is the one
`ladder-deck-2026-09-10.md` recorded, so the f32 arm is the right control.

## 3. The gate decks — where the plan died

`valgrind --tool=callgrind --cache-sim=no --branch-sim=no`, whole run,
`-b --backend cpu -r /dev/null`. "tip" is a clean worktree of `6f60612`;
"off" is this tree as shipped (`op_tran_split = false`); "split build" is this
tree with the const flipped, measured with the env var unset and set.

| Ir | tip `6f60612` | this tree, off | split build, f64 | split build, **split** | `-Djac-f32=mos1,mos6` |
|---|---:|---:|---:|---:|---:|
| `scaling/parallel_inverters_100` | 374,112,626 | **374,112,583** | 377,849,328 | **380,432,392** | 437,042,966 |
| `devices/mos6_inverter` | 127,458,153 | **127,453,308** | 127,514,781 | **129,747,259** | 153,831,586 |

Read three columns:

- **Off is free.** −43 Ir on pi100 (−0.00001%) and −4,845 on mos6 (−0.004%)
  against the tip, with 258/258 raws byte-identical (§5). The comptime const is
  what buys this: at `false` the second instantiation is never emitted, the
  `tran_f32` field is `void` and the hook reverts to its old install condition.
- **The split is a loss, +0.68% and +1.75%** against the f64 arm of its own
  binary, at **identical** `nr_iters` (1352 and 884), identical
  accepted/attempts and identical `avg_dt`. This is per-iterate kernel cost,
  not convergence.
- **Compiling it in at all costs pi100 +1.0%** (374.1M → 377.8M on the f64
  path, same source path, same counts) — the extra instantiation moves LLVM's
  decisions in the one that ships. Against a feature worth nothing, that alone
  settles the gate.

### 3.1 Why the −6.38% evaporated: `rank4-collapse` already spent it

`jac-f32-2026-09-10.md` measured pi100 466,359,299 → 436,603,086 (−6.38%) with
an 8-wide derivative basis. Today the f64 tip is **374,112,626** — `limit-body`
and `rank4-collapse` took 20% out of it — while the f32 build reads
**437,042,966**, i.e. essentially the same 436.6M it read then. **The f32 build
did not get the rank-4 win.** It cannot: `rank4-2026-09-10.md` §"w <= 4 — the
narrow side must fit in one ymm" is exactly the condition that makes f32
pointless. At rank 4, `@Vector(4, f64)` is 32 B = one ymm; `@Vector(4, f32)` is
16 B = one xmm running the same instruction count, and every plane write and
every interaction with the f64 residual now pays a convert. The f32 win was a
register-pressure win, and `rank4-collapse` collected it first, in f64, for
every deck instead of for the permitted stems only.

The control for that claim: `convergence/mos_series_r` is the deck whose
`RD=12 RS=9` keeps mos1 **uncollapsed at rank 8**, and there f32 still wins —
4,380,324 → 4,294,987 Ir, **−1.95%**. Wide basis, f32 pays; narrow basis, f32
costs. (It is a `.dc` deck, so the split itself is a no-op on it: 4,382,145,
+0.04%.)

## 4. The trap, named

§6 of `jac-width` warns that both discriminators descend from one circuit. That
warning holds and this pass makes it worse, not better: **`mos_latch_ladder`
cannot discriminate here at all** (§2.2, it has no transient), so the OP-side
evidence for the split is `ngspice/mosmem` **alone** — one deck. Both
discriminators going green is therefore necessary, not sufficient, and in this
case one of the two greens is vacuous.

It does not matter for the verdict, because the split fails on the other side
with a mechanism (§3.1) rather than on a deck count. But if the gate-deck
number ever turns positive again, the OP-side evidence needed is the one
`jac-width` §6 already specified and this pass did not take: **ten independent
stiff-MOS decks, fewer than ~2 losing rung 1**, plus a **whole-corpus
wall-clock** over all 288 decks, which has still never been taken.

## 5. Checks

- **CPU bit-identity.** `benchmark/capture_raws.sh` from a `6f60612` worktree
  and from this tree: **258 of 258 `.raw` byte-identical** (`cmp -s`), **288 of
  288 exit codes identical**. Nothing moved with the switch off, which is the
  whole corpus and not an assumption.
- **GPU untouched.** `DeviceKernel.run` still passes `gpuJacFloat(D)`; the
  `-Djac-f32-gpu` default is still `mos1,mos6`; no PTX input changed.
- **Frozen boundary.** `layoutHash`, `abi_version = 7`, scatter tapes, PODs,
  pattern CSC, `[]f64` planes: unchanged (§1).
- **`zig build test --summary all`: 339/339 steps, 414/414 tests.** (414, not
  the 413 of `jac-width`: `options-tnom` added one.)
- **No new test.** The live predicates `jacFloat`/`gpuJacFloat` keep their six
  assertions in `engine.test."jac width: one device, two instantiations"`; the
  split's own logic is compiled out at `op_tran_split = false`, and a test for
  code that is not emitted pins nothing. Flipping the const is what re-arms it.

## 6. Recommendation

**Leave the CPU default at f64, and stop treating the OP as the reason.**
`jac-width` §6 blamed the gmin ladder; that diagnosis was right and the fix
works, but it is now beside the point. On today's tip the f32 Jacobian loses on
the CPU *in the transient too*, at unchanged iteration counts, because the
register win it was made of has already been taken in f64 by `rank4-collapse`.

What would have to be true to revisit it:

1. **A permitted device whose basis is wider than 4.** That is the population
   where f32 still pays (`mos_series_r`, −1.95%, rank 8). mos1/mos6 collapse,
   so the shipped permission list is precisely the set that no longer benefits.
   A device with `n_u > 8` uncollapsed, or a corpus where most MOS instances
   carry RS/RD, would change the sign — and is measurable in one afternoon by
   flipping `op_tran_split`.
2. **Then** the OP-side evidence of §4 (ten independent stiff-MOS decks, whole-
   corpus wall clock), because the split's OP half is proven on one deck.

Until (1), the split is a loss with a mechanism, and the honest shape for it is
a compiled-out const with this document attached.

## 7. What was NOT done

- **No build flag, no VerA decl, no `-Djac-f32-tran`.** The experiment needed
  neither: the permission already existed and the phase already reached the
  batch. A flag for a measured-negative switch is plumbing for nothing.
- **No f32 anywhere but the derivative vector** — unchanged from `jac-width`.
- **No GPU change.**
- **No whole-corpus wall clock.** Still the missing number, still called out.

## Settled by this pass

| claim | the measurement |
|---|---|
| the split removes the ladder fall-through | `mosmem` 50 OP iterates and `plain conv=true` under the split, against 144 and 11 gmin rungs at f32 |
| it keeps no transient win, because there is none left | pi100 +0.68%, mos6 +1.75% Ir at identical `nr_iters`; the f32 build is +16.8% / +20.7% against a tip that `rank4-collapse` already improved 20% |
| the reason is the rank-4 basis, not convergence | `mos_series_r`, mos1 uncollapsed at rank 8, is still −1.95% under f32 |
| `mos_latch_ladder` cannot answer this question | it is a `.dc` deck: byte-identical raw under the split |
| the mixed-width handoff is sound | residual and planes are f64 at both widths; accepted/attempts/`nr_iters`/`avg_dt` identical on all three decks |
| shipping it off costs nothing | 258/258 raws, 288/288 exits, −43 Ir on pi100 |

## Reproducing

```
git worktree add ../ARPice-base 6f60612 --detach && (cd ../ARPice-base && zig build -Dgpu=false)
zig build                                        # off, as shipped
zig build -Dgpu=false -Djac-f32=mos1,mos6 -p /tmp/jacf32-out     # the full-f32 arm

# the split arm: flip `op_tran_split` to true in src/devices/engine.zig, rebuild,
# then ESPICE_JAC_TRAN_F32=1 selects it at runtime.

for D in ngspice/mosmem convergence/mos_latch_ladder; do
  ZP_OPDBG=1 ZP_TRAN_STATS=1 zig-out/bin/espice -b --backend cpu -r /dev/null \
    benchmark/fixtures/$D/circuit.sp 2>&1 | grep -E 'ladder:|tran-stats|newton it=' | wc -l
done

valgrind --tool=callgrind --cache-sim=no --branch-sim=no \
  zig-out/bin/espice -b --backend cpu -r /dev/null \
  benchmark/fixtures/scaling/parallel_inverters_100/circuit.sp

./benchmark/capture_raws.sh /tmp/raws-before   # from ../ARPice-base
./benchmark/capture_raws.sh /tmp/raws-after    # from here
```
