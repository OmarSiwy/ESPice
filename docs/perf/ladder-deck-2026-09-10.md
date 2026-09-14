# A convergence fixture that sees the ladder — 2026-09-10

`benchmark/fixtures/convergence/` scored decks on the **answer**. Nothing in it
scored the **path**. A Jacobian perturbation — an f32 Jacobian, a narrowed
`Dual` width, a cheaper limiter — can flip `plain Newton converged` to `plain
Newton failed` while leaving the answer inside `reltol`, and then the whole
gmin/source ladder is paid at every operating point that flipped. Measured
instance, found by accident in the `ngspice/` group: `-Djac-f32=mos1` on
`ngspice/mosmem` takes the OP from 50 to 144 NR iterates, +13.7% whole run,
same answer.

This page records why `mosmem` is hard, what did and did not reproduce it, and
the deck that ships: **`convergence/mos_latch_ladder`**.

## The instrument

```
ZP_OPDBG=1 <binary> -b --backend cpu -r /tmp/x.raw <deck> 2>&1 | grep -c "plain conv=true"
```

Binaries: `/tmp/jacf32/bins/espice-f64` and `espice-f32` (the latter built
`-Djac-f32=mos1`). Three counts are worth reading, not one:

| count | grep | means |
|---|---|---|
| ladder entries | `ladder: plain` | how many OPs took a cold restart at all |
| plain converged | `plain conv=true` | how many of those rung 1 handled |
| gmin rungs | `ladder: gmin` | the fall-through tax |

Total Newton iterates come from `ZP_NEWTON_DEBUG=1 | grep -c "newton it="`.
`ZP_NEWTON_DEBUG` also prints the `why=` reason a gate refused an iterate,
which is what identified the failure mode below.

`mosmem` baseline: **f64 = 1, f32 = 0**; 50 plain iterations against `ITL1`=100
in f64, blown past 100 in f32.

## What makes `mosmem` hard

Read off `ZP_NEWTON_DEBUG` on the f32 run. Every refused iterate says
`why=delta`, and the shape is unmistakable:

```
newton it=14 |F|=1.277e-6@12(6) dx=-7.138e1@9(3) ... conv=false why=delta
newton it=15 |F|=1.267e-2@9(3)  dx= 6.807e1@9(3) ... conv=false why=delta
```

`|F|` is down at 1e-6 A while `dx` is still tens of volts, and it is not
descending — it oscillates for dozens of iterations. That is not a stiff
circuit, it is a **chaotic Newton walk**, and the nodes carrying it are
`3, 4, 5, 6, 8` — every internal high-impedance node. Three things put it
there:

1. **No resistive path to a rail anywhere.** Every conductance on those nodes
   comes from a MOSFET, and the model is `LEVEL=1`, which has **no
   subthreshold region**: below `Vt` the drain current is exactly zero and so
   is the row. The five diode-connected `w=5u` loads sit on the wrong side of
   that kink, so a node's conductance toggles between zero and finite as the
   iterate crosses it.
2. **`GAMMA=1.83` puts the body effect inside the feedback path.** Each load
   is a source follower whose own `Vt` moves with the node being solved for.
   The kink chases the iterate instead of standing still.
3. **`m7`/`m8` are a latch.** Two basins. The Newton path between them is not
   a descent, which is where the oscillation comes from.

The gmin rung fixes it for the obvious reason: the shunt gives every node a
finite conductance, so the zero-row chatter cannot happen. `mosmem` f32 walks
the gmin ladder 1e-3 → 1e-12 with 2–9 iterations per rung and never struggles.

**The `PULSE` sources are not load-bearing.** Replacing all three with DC
sources at their `t=0` values (`vs`=2, `vw`=0, `vwb`=2) and `.tran` with `.op`
reproduces the split exactly: 50 plain iterations f64, >100 f32, `conv` 1 vs 0.
The OP that fails is a standalone bias point after all — the states the pulses
drive through are not what makes it hard.

## What did not work

### Deletion and substitution from `mosmem` (28 measurements)

Dropping `m11`/`m12` (the output buffer) is free — 10 devices still give
1 vs 0. Past that, **every** further reduction kills it:

| variant | f64 / f32 plain iterations | discriminates |
|---|---|---|
| `mosmem` minus `m11`,`m12` (10 devices) | 50 / 100 | **yes** |
| minus the latch `m7`,`m8` | 21 / 21 | no |
| minus the right half `m2`,`m4`,`m6` | 20 / 20 | no |
| minus the left half `m1`,`m3`,`m5` | 20 / 20 | no |
| minus the latch loads `m9`,`m10` | 24 / 24 | no |
| `m3`,`m4` → 1 MEG resistors | 33 / 25 | no |
| `m9`,`m10` → 1 MEG resistors | 21 / 21 | no |
| `m1`,`m2` → resistors | 21 / 21 | no |
| `m5`,`m6` → resistors | 20 / 20 | no |
| single deletion of any one of the ten | all 16–33 | no (10/10) |

The pattern is consistent: anything removed drops plain Newton from ~50
iterations to ~20, which is nowhere near the `ITL1` cliff, and the f32
perturbation has nothing to push over.

### Purpose-built small latches (7 topologies)

Built rather than reduced, so the physics stays sane:

| deck | devices | discriminates |
|---|---|---|
| latch + loads + pass gate + diode pull-up + write pull-down | 7 | no |
| latch + loads + direct write pull-down | 5 | no |
| symmetric latch + loads + two write pull-downs | 6 | no |
| symmetric, latch + pull-ups + pass gates, no latch loads | 8 | no |
| symmetric, latch + loads + pass gates, no bit-line pull-ups | 8 | no |
| symmetric, latch + loads + pull-ups, no pass gates | 8 | no |
| symmetric, latch + loads + pull-ups + pass gates, no writes | 8 | no |

This is the same result the three previously deleted candidates got — a
cross-coupled latch on `mosmem`'s own model card was already tried twice and
gave `plain conv=true` 2/2. **The model card was never the problem, and neither
is bistability on its own.** Ten devices is the floor.

### Model-card reductions

Removing `cgso`/`cgdo`/`cbd`/`cbs` is free (they are capacitances; the OP does
not see them). Removing `.opt abstol=1u` is free. Removing `lambda=0.115` is
not — it kills the discrimination.

That last one is the warning sign. Sweeping `lambda` on the single-`.op` form:

| lambda | 0 | 0.02 | 0.05 | 0.08 | **0.115** | 0.15 | 0.2 | 0.3 |
|---|---|---|---|---|---|---|---|---|
| f64 iterations | 21 | 29 | 26 | 59 | **50** | 57 | 20 | 16 |
| f32 iterations | 21 | 29 | 26 | 64 | **100** | 45 | 20 | 16 |
| discriminates | no | no | no | no | **yes** | no | no | no |

Non-monotonic, 16 to 100 with no structure — the chaotic walk again. As a
**single** operating point this class is a coin flip that only `lambda=0.115`
happens to win. Shipping that would have been the knife-edge fixture the brief
warns about: real the day it is committed, silently dead after any unrelated
reordering.

## What worked: sample the walk, do not bet on one throw

A coin flip becomes an instrument when you throw it often enough. `dc.run`
warm-starts interior sweep points with plain Newton at `ITL2`, and falls into
`op.solveLadder` only when that warm start fails — so a DC sweep over the
chaotic region produces several **independent cold OP solves**, each one a
throw. The count over the sweep is a statistic, not a coin flip.

Sweeping the write input `vw` from 0 to 5 V walks the cell through its
metastable write point. Measured on the shipped deck:

|  | ladder entries | plain converged | gmin rungs | Newton iterates |
|---|---:|---:|---:|---:|
| f64 | 3 | **3** | 0 | 360 |
| `-Djac-f32=mos1` | 3 | **1** | 22 | 547 |

Same three cold restarts. Two of them lose rung 1 under f32 and pay the gmin
ladder. **+52% Newton work for the same answer** — max deviation 1.1 mV on a
5 V rail, inside `reltol`=1e-3.

### It is a region, not a knife edge

The whole point of the sweep form. Every row below was measured on the shipped
deck with one parameter moved:

| lambda | 0.05 | 0.08 | 0.1 | **0.115** | 0.13 | 0.15 | 0.2 |
|---|---|---|---|---|---|---|---|
| f64 plain / entries | 3/3 | 5/5 | 3/3 | **3/3** | 2/2 | 2/3 | 3/4 |
| f32 plain / entries | 2/2 | 3/3 | 4/4 | **1/3** | 3/3 | 3/4 | 3/3 |
| differs | yes | yes | yes | **yes** | yes | yes | yes (entries) |

| gamma | 1.4 | 1.6 | **1.83** | 2.0 | 2.2 |
|---|---|---|---|---|---|
| f64 plain | 2 | 0 | **3** | 2 | 2 |
| f32 plain | 0 | 2 | **1** | 3 | 2 |
| differs | yes | yes | **yes** | yes | no |

| sweep step | 0.05 | **0.1** | 0.2 | 0.25 | 0.5 |
|---|---|---|---|---|---|
| f64 plain | 3 | **3** | 3 | 3 | 2 |
| f32 plain | 1 | **1** | 2 | 1 | 1 |
| differs | yes | **yes** | yes | yes | yes |

`lambda=0.115`, `gamma=1.83` is kept because it is the cleanest reading —
identical ladder entries on both binaries, so the difference is unambiguously
rung 1 failing and not a different number of cold restarts.

## The deck

`benchmark/fixtures/convergence/mos_latch_ladder/circuit.sp`. Ten MOSFETs, four
DC sources, one `.dc` sweep, no capacitors, no `.options`. `mosmem`'s numbered
nodes are renamed to what they are (`bl`/`blb`/`q`/`qb`/`wl`/`d`/`db`), which
is most of what made the original unreadable as convergence coverage.

Verified against ngspice 44.2 via
`check_fixtures.py --category convergence --reference`: **PASS on all three of**
`espice-f64`, `espice-f32` and the shipping `zig-out/bin/espice`. The two
pre-existing `--reference` failures in the category (`high_gain_fb`, `schmitt`,
both "missing reference signal i(e1)") are unrelated and untouched.

Runtime 7 ms espice / 15 ms ngspice.

## Why `mosmem` was not simply moved into `convergence/`

That was the allowed fallback. It is not needed: the sweep form is a strictly
better instrument than `mosmem` itself — 3-vs-1 over three independent cold
solves instead of 1-vs-0 over one, robust across three parameter axes where
`mosmem`'s single OP is robust across none. `mosmem` stays where it is as a
`.tran` regression; `mos_latch_ladder` is the convergence coverage.

## What breaks this fixture

By design, anything that perturbs the Jacobian or the pivot sequence and so
moves the plain-Newton iteration count across `ITL1`:

- an f32 Jacobian (`-Djac-f32=mos1`) — measured above;
- a narrowed `Dual` width for mos1;
- a cheaper or reordered limiter;
- an ordering change that alters the pivot sequence.

None of them change the answer. All of them change the count. **Read the count,
not just the pass.**
