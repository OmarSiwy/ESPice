# Device kernel instruction count: where VerA's eval spends more than ngspice

2026-09-09. Scope: the generated device kernel only (VerA), measured against
ngspice 44.2's hand-written `MOS1load`. Iteration counts are already at parity
(espice `nr_iters=1352`, ngspice 1319 `MOS1load` calls on the same deck), so
every remaining gap is per-evaluation cost, not convergence.

**Result.** mos1 `evalQ` **965 → 754 Ir per instance-eval (−22%)** from three
codegen changes, raw output byte-identical throughout. End to end,
`parallel_inverters_100` 754,946,900 → 704,917,028 (**−6.6%**) and
`devices/mos6_inverter` 255,720,597 → 248,507,129 (**−2.8%**), against ngspice's
513,451,304 and 148,854,077. The kernel is now at parity with `MOS1load`'s 759
self-cost and ahead of its 1053 full per-instance cost; the surviving end-to-end
gap is 1.37x and 1.67x.

Read this document in order. It is chronological, and the second half retracts
two things the first half asserted — the "1536-byte return ABI" and the
"24% dead-path bloat" were both artifacts of a `noinline` measuring wrapper.
The habit worth copying is that every lever here was priced before it was
built, and four of the six were killed by that pricing.

## The rig

Two metrics, both rerunnable, in `/tmp/devbench` (`measure.sh`):

- **STATIC** — instructions in a `noinline` wrapper around `mos1.evalQ`,
  read off `objdump`. Deterministic and diffable.
- **DYNAMIC** — callgrind Ir per eval from a two-point fit (1000 vs 3000
  iterations) that cancels process startup. The driver launders the
  model/instance pointers, because in espice they arrive from a batch and
  nothing about them is a compile-time constant; without that the whole
  parameter prologue folds away and the rig measures nothing. It also consumes
  every derivative lane — reading one lets LLVM scalarize the dual and
  dead-code the rest, which silently turns a width sweep into a no-op.

End-to-end is total program Ir under `valgrind --tool=callgrind
--cache-sim=no --branch-sim=no` on
`benchmark/fixtures/scaling/parallel_inverters_100` (200 MOS1 instances).

## Ground truth: what ngspice's 759 buys

`MOS1load` self is **759 Ir per instance per Newton iteration**, and that
number covers residual + analytic Jacobian + limiting + convergence test +
state save + **26 stamp writes**. VerA's `evalQ` buys residual + Jacobian
columns only, so the comparison flatters VerA before it starts.

| | ngspice `MOS1load` | VerA `evalQ` (baseline) |
|---|---:|---:|
| Ir / instance-eval | 759 | 965 |
| FP-arith instructions | 182 | ~300 |
| move/cvt share | 49.9% | 48.0% |
| independent derivative directions | **3** (vgs, vds, vbs) | **8** (one per solver unknown) |
| `exp` calls / eval | 1.45 | 2.00 |
| `sqrt` / eval | 1.00 | (6 emitted) |

Both are half data movement. The difference is not that the emitted code is
sloppy — it is that every intermediate carries eight partial derivatives when
the physics has three independent bias directions, and that the kernel
materialises a 1536-byte return struct where ngspice stamps as it goes.

## The width sweep — the measurement that reprices everything

Same physics, same values (so every branch takes the same direction), only the
dual's derivative width varied:

| derivative width | 1 | 2 | 3 | 4 | 8 |
|---|---:|---:|---:|---:|---:|
| Ir / eval | 634 | 695 | 750 | 761 | **965** |

Two conclusions, and the second is the important one:

1. The entire derivative vector costs **331 of 965 Ir (34%)**. Narrowing is
   real money but it is bounded — a perfect scalar-derivative kernel still
   pays 634.
2. **A global reduced tangent basis is a measured regression, not a win.**
   mos1's probe incidence has rank 5 (6 nodes touched, one component), and on
   AVX2 `@mulAdd` over `@Vector(5, f64)` legalises to 14 instructions against
   `@Vector(8, f64)`'s 13. Widths 3, 5 and 6 all lose to 8. Only widths ≤ 4
   pay. So "seed the independent probe directions" — the obvious
   OpenVAF-shaped answer — is architectural work for a negative payoff on this
   CPU. It would pay on a GPU, where a lane is a scalar register.

What does pay is **per-value** narrowing: no temporary in mos1's core ever has
more than 4 of its 8 lanes structurally nonzero, and in probe-difference
coordinates 116 of 177 core S-ops (66%) have exactly one active direction.
`src/ir/analysis.zig:709-767` already computes the per-value dependency mask
that would drive it (`buildDeps`/`defDeps`, a sound monotone union fixpoint
over every value); today it is consumed only to elide *stamps*
(`jac_pattern`/`q_pattern`), never to narrow what is *computed*.

## What landed

**The temperature hoist stopped at the first `if`.** VerA hoists
parameter/temperature-only subtrees into `precompute` (ngspice's `<dev>temp`
phase, once instead of per eval). Two gates were holding back the whole
`<dev>temp` chain of every machine-converted SPICE model:

1. A root had to contain a **libm-class op** — "anything cheaper is not the
   measured cost". That reads the cost of one root and misses the shape SPICE
   temp code actually has: a long ladder of cheap parameter arithmetic
   (`cox = eps/tox`, `leff = l - 2*ld`, `vt = k*T/q`, `beta = kp*w/leff`) where
   no single step is expensive and the sum is the whole phase. mos1 rebuilt 53
   of its 115 core temporaries — every one parameter-only — per instance per
   Newton iteration. Replaced by the comparison the name asks for: a field
   costs one load, so hoist anything that costs more than one load to rebuild.
2. `$param_given` is a `call`, and `pcClass`'s call whitelist held only
   `$temperature` and `$vt`. But `renderSysCall` spells `$param_given` as the
   Model field `<p>__given` and `$port_connected` as the literal 1 — both as
   parameter-only as a `param_ref`. Excluding them was load-bearing: one
   unhoistable guard makes its select unhoistable, and one unhoistable select
   strands every value downstream of it in the core.

**A latent correctness bug the hoist exposed.** `collapse` decides topology, so
a host calls it while building the matrix — before the batch exists and
therefore before the batch runs `precompute` (`src/builder.zig:216` and
`:414`). But `collapse` answers by evaluating the shared `core` at x = 0, and
the core reads `Instance.pc__*`. The retention flags were being read off
unwritten zeros. It only ever worked because no libm-rooted hoist had happened
to land in a collapse condition. Fixed where it belongs — in the generated
`collapse`, which now seeds its own `precompute` on a local copy of the
Instance. `precompute` is a pure function of (model, instance), so that is the
same answer the batch computes later, and the copy leaves the caller's Instance
untouched. This fixes the dynamic (FastVAF `.so`) path too, which has no
`precompute` entry in its vtable and so could not have been fixed host-side.

### Measured

Matched baseline/after pair, both built from the same tree, differing only in
these two codegen changes.

| | baseline | after | delta |
|---|---:|---:|---:|
| mos1 `evalQ`, static insns | 1824 | 1727 | −5.3% |
| mos1 `evalQ`, Ir/eval | 965 | 920 | **−4.7%** |
| `parallel_inverters_100`, total Ir | 754,946,900 | 736,643,631 | **−2.42%** |
| `devices/mos6_inverter`, total Ir | 255,720,597 | 250,925,534 | **−1.87%** |
| ngspice 44.2, same two decks | 513,451,304 / 148,854,077 | — | espice 1.43x / 1.69x |

**Raw output is byte-identical on both decks**, which is the contract for a
non-behavioral codegen change. VerA `zig build torture`: 1239/1242 — the three
failures are the untracked in-progress `ch09_system_tasks/17{7,8,9}_limit_*`
fixtures and are unrelated. espice `zig build test`: 398/400; the two failures
are `devices.test.BJT` collapse-node-count assertions that reproduce
**identically on the pristine generator** (verified by comparing `collapse`'s
alias output across a matched baseline/after pair — bit-identical), so they are
pre-existing. The test expects 1 and 3 nodes where the device retains 2 and 6;
the difference is branch-flow unknowns, which `Builder.addDevice` counts as
allocated nodes.

`Instance` grows from 28 to 62 `pc__` fields on mos1 (+272 B/instance). Note
these are **model-level** quantities living on the instance: 2000 identical
inverters keep 2000 copies of the same 62 numbers where 2 would do. ngspice
splits `MOS1model` from `MOS1instance` for exactly this reason. Splitting the
hoist by whether a root reads `inst.temperature` is the follow-up.

## Round 2: one more win, and four levers killed by measurement

### What landed

**The eager-select rule had a legality test and no cost test.** `renderInst`
emits `S.sel` — both arms evaluated, branchless — whenever `eagerSafe` says it
is legal. Branchless is right when the arms are a few FP ops, because a
mispredict costs more than both. A transcendental inverts that: `exp` is ~50
instructions, so the select pays for the arm it throws away, every iterate.
mos1 measured **2.00 `exp` per instance-eval against ngspice's 1.45** for
exactly this reason — the b-s junction kept its `if` (a multi-use domain op
blocked if-conversion) while the identical b-d junction was flattened. Added
`eagerCostly` beside `eagerSafe`: refuse the eager form when either arm's
inline tree contains a libm-class op.

Worth far more than the `exp` alone, because skipping the arm skips its whole
expression tree — the flattened b-d arm also carried `div` three times and
`min` twice. **900 → 754 Ir/eval.**

The argument that had been keeping these eager was that a lane-parallel S has
no single `.val()` to steer on, so a branch pins lanes. That argument died this
round — see the instance-SIMD entry below.

**`Dual`'s derivative vector was over-aligned.** A vector's natural ABI
alignment is its size (64 B at N=8), padding `Dual` to 128 B for 72 of payload
and making `evalQ`'s return 2048 B for 1152. Nothing reads `d` through a raw
pointer, so `align(@alignOf(F))` costs at most a `movaps`→`movups`.
**920 → 900 Ir/eval**, `[8]S` 768 → 576 B.

### Four levers killed, with the number that killed each

**Per-value derivative narrowing — dead, and the "obvious" version is unsound.**
On AVX2 every width ≤ 4 is ONE vector instruction, so narrowing the 108
popcount-2 values from 4 lanes to 2 saves exactly zero FP. And mos1's smallest
*correct* lane universe is **six**, not four: every dependency mask is a subset
of `{g,b,di,si}` except the `rd`/`rs` series branches, which touch `{d,di}` and
`{s,si}`. `@Vector(6,f64)` lowers to ymm+xmm — the same two FP instructions per
op as `@Vector(8)` — while broadcasts go 209 → 354. Measured k=6: **1088 Ir, a
21% loss.** k=4 measures −26 but is provably wrong: a bit-identity harness over
a bias sweep found 0 mismatches at `rd=rs=0` and **3150 at `rd=12, rs=9`**.
A one-lane-insert contract primitive (`axpy`) was added, measured at 2.95
instructions per component rather than the hoped ~1, and reverted with the rest
— the ledger does not close even at 1.

**Instance-axis SIMD — no-go at 1.17x end-to-end.** Two independent killers.
(1) The sparse stamp is **195 Ir/instance at W=1 and 196 at W=4** — AVX2 has no
`vscatterdpd`, so 61 scattered read-modify-writes per instance never vectorize,
and that is 13% of device eval on its own. (2) With realistic branch arms the
kernel gets **1.67x, not 4x**, because the scalar path takes ONE junction `exp`
and every lane path must take BOTH — mos1 has four such branches. Composed
against a 58% device-eval share: 1.17x, before EEspice's finding that the
sparse solver then takes over at 62.7%. Cost of buying it: de-branching 26
compact models (52 pin sites in mos1, the simplest of them; `lane_clean` is
12/38 today and **not one is a nonlinear semiconductor model**), a second
lane-parallel ABI through `evalRange`/`Sink`, and an instance-sort pass.

**The return ABI — zero.** `evalRange` calls `evalQ` through
`@call(.always_inline, ...)`. There is no call, so there is no ABI, so there is
no sret memcpy to remove. Out-params compiled to byte-identical machine code
(LLVM's function merger deleted the duplicate outright). The 524-instruction
"ABI cost" in the first half of this document was an artifact of the `noinline`
measuring wrapper — the measurement, not the program. Packing the
structurally-zero rows also measured −5, wrong sign: after inlining LLVM has
already folded the never-written rows to zero and deleted their scatters.

**Dead-path outlining — 1.4% ceiling.** The register-pressure premise is true
(68% of moves are spill, 490 of them) but the conclusion is false: **only 196 of
1727 instructions ever execute.** Gutting the entire cold junction-charge arm
buys **13 Ir**. `--outline-chunk` measured **+63% worse** (1503 vs 920);
`noinline` on the cold block bought 0 Ir and pushed hot spills 52 → 62, because
every YMM is caller-saved.

### Can data movement get under 10%? No — the floor is 25–30%

The 14% figure for a hand-written core in the first half of this document was an
artifact: an isolated function whose 8 inputs all arrived in `xmm0-7` via the
ABI, with **zero input loads**. The same arithmetic in a real loop measures
35.7% (AoS) / 46.0% (SoA).

- mov% < 10% needs **≳18 flops per f64 word moved**. The MOS1 core has 3.0.
- **~50% is an attractor** for any kernel that spills — ngspice 49.9%, ours
  48.4%, and a synthetic sweep hits it at 32 live vectors. Spill onset is 14–16.
- Widening does not help: mov% is **width-invariant** (W=2 and W=4 both 27.8%),
  because it divides movement and arithmetic by the same W.
- SoA is *worse* than AoS for scalar eval — eight base pointers blow GPR
  pressure where AoS gets eight fields from one base with displacements.
- Best case for the largest model we have, BSIM4, with a perfect allocator
  (659 live values into 16 registers) is 13.4%.

So ngspice's 49.9% is not an AoS defect to beat, and mov% is a symptom of
spill, not an independent target. Stop optimizing it.

## The remaining ledger

Per mos1 `evalQ`, now **754 Ir/eval**. ngspice's `MOS1load` self is 759 and its
whole per-instance device evaluation is 1053, so the kernel is at parity on the
narrow comparison and ahead on the fair one. End to end the gap is now 1.37x
(`parallel_inverters_100`) and 1.67x (`mos6_inverter`).

| item | measured | where | status |
|---|---:|---|---|
| `jac_rows` / `q_rows` — which residual rows are ever WRITTEN | ~22 Ir/instance | VerA codegen + contract + tb, then `evalRange` | patch drafted, **not applied**, `/tmp/vera-rows.patch` |
| temp ladder still stranded behind a phi | 20-40 Ir | `pcClass` refuses `.phi`; precompute renders expressions, not control flow | open |
| MIR-level GVN (`h[26].div(h[3])` rendered 3x) | low | LLVM already recovers most (`vdivsd` 38 -> 28 from the hoist alone) | not worth it |

**`jac_rows` is the one with a real invariant behind it, and the reason it is
not applied is the reason it is worth having.** `jac_pattern`/`q_pattern` answer
"which COLUMNS of this row can be nonzero" — a term whose value depends on no
unknown ORs zero into the column mask *while still writing the row*. `isource`
ships exactly that: `jac_pattern = {0, 0}` and `eval` stamping the DC current
into both rows. **A host that reads a clear pattern row as "identically zero"
deletes every independent current source in the netlist.** The reactive failure
is quieter and worse: a `ddt()` of something varying in `t` and not `x` would
leave `q_tape` holding a frozen zero for a live state and `stepBound` would drop
a real LTE bound. The safe predicate is "row `ru` is ever written", which the
generator knows and does not emit. Landing it needs a full benchmark run to be
worth the risk, which did not fit in this session.

### Dead code found on the way past

`canDedup(D)` requires `@hasDecl(D, "PrepCache")`, and `PrepCache` is **not** in
`contract.zig`'s `allowed_pub_decls` — a device declaring it fails validation.
So `SinkT.dedup` is comptime-false for every device that can exist, and
`tryCached`, `hashVoltages`, `store`/`storeQ` and the per-lane eval cache are
unreachable. `engine.zig:1093` says as much itself. Worth deciding whether to
wire it up or delete it; note that a working dedup would have been a strong
argument against instance-axis SIMD on `parallel_inverters_2000`, and without it
that deck evaluates every one of its 4000 instances.

## Reproducing

```
# kernel, both metrics, ~40 s
/tmp/devbench/measure.sh <tag>

# end-to-end, ~4 min each
valgrind --tool=callgrind --cache-sim=no --branch-sim=no \
  --callgrind-out-file=/dev/null \
  zig-out/bin/espice -b -r /tmp/o.raw \
  benchmark/fixtures/scaling/parallel_inverters_100/circuit.sp

# a true baseline needs a matched build, not a binary left over from a prior
# session — a stale one cost this audit an hour and a 17.8% claim that was not
# real. Revert the codegen hunks, then:
zig build --prefix /tmp/espice-base-out
```
