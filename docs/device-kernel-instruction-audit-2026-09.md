# Device kernel instruction count: where VerA's eval spends 2x ngspice

2026-09-09. Scope: the generated device kernel only (VerA), measured against
ngspice 44.2's hand-written `MOS1load`. Iteration counts are already at parity
(espice `nr_iters=1352`, ngspice 1319 `MOS1load` calls on the same deck), so
every remaining gap is per-evaluation cost, not convergence.

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

## The remaining ledger, in order of measured payoff

Per mos1 `evalQ`, now 920 Ir/eval against ngspice's 759-for-more-work.

| item | est. Ir/eval | where | verdict |
|---|---:|---|---|
| per-value derivative narrowing (width ≤ 2 in probe-difference coords) | ~225 | `codegen.zig` `zigTy`/`renderInst`/`renderVal` + a narrow scalar beside `R`/`P` | medium, ~200 lines, stays inside the kernel — does **not** cross the frozen GPU boundary |
| `res`/`q` materialisation (1536 B returned, 384 B informative; `Dual(8)` is 96 B of which 24 is padding) | ~100–200 | out-params instead of by-value return, or fusing the scatter into the device | medium/architectural |
| `exp` under an if-converted guard runs both arms (2.00 vs ngspice's 1.45) | ~27 | `renderInst`'s select case needs a cost model beside `eagerSafe`'s legality test | **do not take** — see below |
| redundant inline subexpressions (`h[26].div(h[3])` rendered 3x in one expression) | 30–60 | no GVN on MIR | low — LLVM already recovers most of it (`vdivsd` 38 → 28 from the hoist alone) |
| temp ladder still stranded behind a phi | 20–40 | `pcClass` refuses `.phi`; precompute renders expressions, not control flow | medium |

### Why the `exp` fix is on the do-not-take list

Refusing to if-convert an arm containing a transcendental would save ~27
Ir/eval. It would also pin lanes on every model that has one. Instance-axis
SIMD — evaluating W instances per vector, the only 3-4x lever left — requires
the opposite: no x-dependent scalar branches, everything a select. mos1 emits
no `lane_clean` decl today, so it is already pinned; making that worse to buy
2.8% would be trading the 4x for the 1.03x.

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
