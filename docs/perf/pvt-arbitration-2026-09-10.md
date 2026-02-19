# Arbitration — `ensemble/pvt_corners` and the four other contested fixtures

Two audits landed the same day with opposite verdicts on `ensemble/pvt_corners`:

- `docs/perf/fail-audit-2026-09-10.md` §7 — **ngspice is wrong**; espice 3.5x
  closer to the converged answer, ngspice overshoots its own 3.3 V rail by
  156 mV.
- `docs/perf/ref-sims-2026-09-10.md` "Where espice is the outlier" — **espice is
  wrong**; Xyce 7.10 agrees with ngspice against espice on `pvt_corners`,
  `mos6_inverter`, `ngspice/mosamp`, `parallel_inverters_2000` and `vacask/mul`,
  and there is no fixture where ngspice is the outlier.

Neither was quotable until this. This document is the arbitration. Nothing in
the engine changed; no fixture changed; no tolerance changed.

## The instrument

Both positions are re-derived from scratch with one instrument applied to all
three simulators symmetrically:

1. Run each deck at its default `tmax` and at two or three progressively
   tighter explicit `tmax` values, in **all three** engines.
2. Show the three engines converge to a **common** limit (cross-engine
   agreement at the tightest grid, plus each engine's own grid-to-grid motion).
3. Score every engine's **default** trace against that common limit, with the
   suite's own comparator — per-variable RMS and max normalised by
   `max(peak, span, 1)`, including the ±`max(dt_lo,dt_hi,dt_cand)` 9-point edge
   re-sample of `benchmark/src/runner.zig:515-537`.
4. Where an analytic answer exists, compute it and let it outrank all three.

The comparator is a Python replica of `comparePlots`, validated against the
committed table before use: on `ensemble/pvt_corners` it reproduces
`ref-sims`'s ngspice column to four digits (`ref=ng cand=esp` → max 9.074e-2,
rms 3.922e-3 vs the table's 9.07e-2 / 3.92e-3) and its Xyce column
(`ref=xy cand=esp` → max 1.167e-1 vs the table's 1.17e-1). Script and every raw
in `/tmp/arb` (`raw.py`, `cmp.py`); decks are the committed fixtures with a
`tmax` field appended to the `.tran` card and nothing else.

Binaries: espice `/home/omare/Documents/Projects/Zig/ARPice/zig-out/bin/espice`
(main tree, branch `spice-audit` at `6aa1468`); ngspice the pinned nixpkgs
44.2 at `/nix/store/bywwgg84ccx0544z9qrfm4zc4ls30ghd-ngspice-44.2/bin/ngspice`;
Xyce `/nix/store/7glhfffprbvfz11bi9pd1fr5np8nw5df-xyce-7.10.0/bin/Xyce`. The
from-source ngspice 44.2 at
`/home/omare/Documents/Projects/Zig/ngspice-44.2-fromsource/bin/ngspice` was
used once, as a control, and is named where it appears — it produced
**bit-identical** values to the pinned build on `pvt_corners`, so the 8.8-16.2 %
instruction-count difference between the two builds is a performance fact only.

## Verdicts

| fixture | who is furthest from the converged limit | margin (rms vs limit) | settled by |
|---|---|---|---|
| `ensemble/pvt_corners` | **ngspice** | xy 2.6e-5 < **esp 2.5e-4** < ng 8.9e-4 | 3-engine convergence + an analytic rail bound |
| `devices/hfet_inverter` | **ngspice** | **esp 1.9e-3** < ng 1.0e-2 | 2-engine convergence (no third reference exists) |
| `ngspice/mosamp` | **espice** | xy 8.6e-4 < ng 1.8e-3 < **esp 2.5e-3** | 3-engine convergence |
| `devices/mos6_inverter` | **espice** | ng 1.2e-3 < **esp 2.1e-3**; Xyce recused | 2-engine convergence |
| `vacask/mul` | espice, marginally | xy 2.3e-4 < ng 7.0e-4 < **esp 8.8e-4** | 3-engine convergence |
| `scaling/parallel_inverters_2000` | **nobody — tie** | **esp 2.20e-3** ≈ ng 2.24e-3; xy 2.5e-4 | 3-engine convergence |

The conflict is **only** about `pvt_corners` and `parallel_inverters_2000`.
`mosamp`, `mos6_inverter` and `mul` were already called espice defects by
position A, so B agreeing there corroborates A. `hfet_inverter` B never scored.

---

## 1. `ensemble/pvt_corners` — ngspice is the outlier

### The deck, and the analytic bound

`benchmark/fixtures/ensemble/pvt_corners/circuit.sp`, 14 lines, one
`.tran 10n 20u`, no `.step`/`.temp`/`.mc`. Confirmed: **not** a corner sweep,
as `fail-audit` §"two corrections" already said.

Node `out` is connected to exactly three things: `M5` (PMOS, source and bulk at
`vdd` = 3.3 V), `M6` (NMOS, source and bulk at 0) and `CL = 100f` to ground.
Both MOS cards are `level=1` with no `TOX`, no `CGSO/CGDO/CGBO`, no `CJ`, no
`CBD/CBS`, so `out` carries **one** reactive element, a capacitor to ground, and
no inductance anywhere in the circuit.

Therefore, exactly:

```
CL · dv_out/dt = I_M5(vdd→out) + I_M6(0→out)
```

For `v_out > 3.3`, `M5`'s channel and its drain-bulk junction both carry current
*out* of the node, and `M6` carries current out of the node; `dv_out/dt < 0`.
Symmetrically for `v_out < 0`. **`v(out)` is bounded in [0, 3.3] in the exact
solution.** No simulator vote is needed.

Measured peak `v(out)` over the fall event at 6.015 µs (run: `/tmp/arb`,
`{esp,ng,xy}_{def,t1n,t100p,t10p}.raw`):

| `tmax` | espice | ngspice (nixpkgs) | Xyce |
|---|---|---|---|
| default | 3.301073 (+1.1 mV) | **3.456270 (+156.3 mV)** | 3.300000009 (+9 nV) |
| 1 ns | 3.306496 (+6.5 mV) | **3.569565 (+269.6 mV)** | 3.300000041 |
| 100 ps | 3.299999997 | 3.299999997 | 3.299999996 |
| 10 ps | 3.299999997 | 3.299999997 | 3.299999996 |

and the matching undershoot: ngspice default `min v(out) = -0.164767`
(-165 mV below ground), espice `-1.5e-6`, Xyce `-5.1e-8`.

**Position A's headline claim is confirmed and is not an artifact.** There is no
inductor, the probe is on the right net, and the rail is 3.3 V by the `Vdd`
card. The from-source ngspice 44.2 build reproduces it to every digit
(`ng2_def.raw`: 3.456269638 / -0.164766932), so it is not a build artifact
either. It gets **worse**, not better, when `tmax` is tightened to 1 ns — the
signature of trapezoidal ringing excited by a stepped-over event, not of
truncation error.

### The mechanism, in the grids

ngspice's default grid across the fall (`ng_def.raw`, 6.0140-6.0200 µs):

```
6015.103508 ns   v(o2)=3.292993   v(out)=0.000000
6017.558216 ns   v(o2)=0.000000   v(out)=3.098782      <- one 2454.7 ps step
6019.237859 ns   v(o2)=0.000000   v(out)=3.456270      <- 156 mV over the rail
6020.000000 ns   v(o2)=0.000000   v(out)=3.190288
6020.157870 ns                    v(out)=3.263906
6020.473611 ns                    v(out)=3.312272
6021.105092 ns                    v(out)=3.292504
6022.126848 ns                    v(out)=3.305521      ... decaying ± ring
```

espice's minimum step in the same window is 0.36 ps; Xyce's is 0.0057 ps.
ngspice's is 157.9 ps, and the step that lands *on* the event is 2454.7 ps.

How long is the event? Analytically: `M5` in saturation carries
`Id = ½·kp·(W/L)·(Vgs−Vt)² = ½·25µ·20·2.6² = 1.690 mA`, so charging `CL = 100f`
through 3.3 V takes at least `C·ΔV/I = 195.3 ps`. The converged trace
(`esp_t10p.raw`) measures the 10-90 % rise of `v(out)` at **223.3 ps**, 14 %
above the constant-current bound — exactly as the triode tail predicts.

**ngspice's default step at that event is 2454.7 ps: 11x the entire transition
of the node it is integrating.** That is the whole finding. Everything
downstream — the 156 mV overshoot, the ring, the 868 ps edge error — follows
from it.

Corroboration that it is the integrator and not the model: the same deck with
`.options method=gear` in ngspice (`ng_gear.raw`) drops the overshoot to
3.340707 (+41 mV) and the error against the converged limit from 8.861e-4 to
4.847e-4 rms. Gear is L-stable and does not ring; the overshoot goes with it.

### Do the three converge to a common limit? Yes

| comparison | max | rms |
|---|---|---|
| esp vs ng, both `tmax=10p` | 6.428e-4 | 8.277e-7 |
| esp vs xy, both `tmax=10p` | 4.646e-3 | 1.443e-5 |
| ng vs xy, both `tmax=10p` | 4.650e-3 | 1.460e-5 |

Xyce's residual shrinks 3.9e-2 → 4.6e-3 max (2.5e-4 → 1.4e-5 rms) going from
`tmax=100p` to `10p`, i.e. it is still converging toward the other two rather
than sitting at a different answer. Independent scalar check — the time `v(o2)`
crosses 1.65 V on the rise:

```
tmax=100p:  esp 1.004899669 us   ng 1.004899669 us   xy 1.004870078 us
tmax= 10p:  esp 1.004870051 us   ng 1.004870050 us   xy 1.004870078 us
```

Two different time-integration formulas agree on that edge to **0.03 ps**.
The common limit is real: **1.0048700 µs**.

### Scoring the defaults against the limit

Robust to which engine's converged run is used as the reference grid:

| reference grid | espice default | ngspice default | Xyce default |
|---|---|---|---|
| `esp` @10p | 1.049e-1 / **2.480e-4** | 1.632e-1 / **8.862e-4** | 4.658e-3 / **2.624e-5** |
| `ng` @10p | 1.049e-1 / 2.480e-4 | 1.632e-1 / 8.861e-4 | 4.663e-3 / 2.625e-5 |
| `xy` @10p | 1.235e-1 / 4.647e-4 | 2.158e-1 / 1.022e-3 | 2.991e-3 / 2.632e-5 |

and on the edge time, against the limit 1.0048700 µs:

```
espice  default 1.004873063 us     3.0 ps late
ngspice default 1.004031457 us   838.6 ps early
Xyce    default 1.004870078 us     0.03 ps
```

**Verdict: ngspice is the outlier on `pvt_corners`.** It is the furthest of the
three from the common converged limit on every measure — 3.6x espice's rms,
34x Xyce's — and it is the only one whose default trace leaves the physically
reachable voltage range.

espice is not thereby vindicated. Xyce's default is **9.5x** closer to the limit
than espice's (2.6e-5 vs 2.5e-4 rms) and 100x better on the edge time. On this
deck espice is second of three, not first.

### Why position B read the opposite

B never computed ngspice-against-Xyce. The runner only ever compares espice to
a reference (`compareRawFiles(io, gpa, ref_raw, zp_raw, …)`), so
"espice FAILs ngspice and espice FAILs Xyce" is the most the table can say, and
B read that as "ngspice and Xyce agree with each other". On this fixture they do
not. All three pairwise comparisons of the default runs:

| ref | cand | max | rms | would the gate pass? |
|---|---|---|---|---|
| ng | esp | 9.074e-2 | 3.922e-3 | FAIL |
| xy | esp | 1.167e-1 | 3.015e-2 | FAIL |
| **xy** | **ng** | **2.094e-1** | **4.559e-2** | **FAIL** |
| esp | ng | 1.176e-1 | 9.471e-3 | FAIL |
| esp | xy | 1.016e-1 | 4.069e-3 | FAIL |
| ng | xy | 6.732e-2 | 3.945e-3 | FAIL |

Xyce disagrees with ngspice (4.56e-2 rms) **1.5x more** than it disagrees with
espice (3.02e-2). There is no majority here to be outside of. A binary
PASS/FAIL against a 1e-3 gate discards exactly the ordering that decides the
question.

---

## 2. `devices/hfet_inverter` — ngspice is the outlier; "13.7x" is not the right number

No third reference exists: Xyce has no HFET (`Model is required for device Z1`,
reproduced here — `d/hfet_*.xy.sp` exits 1) and VACASK ships no deck. The
instrument is therefore two engines only.

espice and ngspice converge to a common limit
(`d/hfet_c.{esp,ng}.raw`, `tmax = 0.02 ps`): **max 9.232e-6, rms 5.359e-7**.

Each default against that limit:

```
espice  default vs 0.02p limit:   max 6.400e-2   rms 1.944e-3
ngspice default vs 0.02p limit:   max 2.790e-1   rms 1.012e-2
```

**ngspice is 5.2x further from the limit on rms, 4.4x on max.** Position A's
direction is confirmed independently.

Its *magnitude* is not. A used `tmax = 2 ps` as its converged reference; that
reference has not converged. The `v(4)` crossing of 1.0 V:

```
tmax = 2    ps:  esp 1.087370411 ns   ng 1.087381740 ns
tmax = 0.2  ps:  esp 1.089577136 ns   ng 1.089577602 ns
tmax = 0.02 ps:  esp 1.089781638 ns   ng 1.089781498 ns
```

The limit is still moving at 2 ps — 2.203 ps, then 0.204 ps, a ratio of 10.8
per 10x grid refinement. Richardson-extrapolated limit **≈ 1.08980 ns**. Against
that:

```
espice  default 1.086682123 ns    3.12 ps early
ngspice default 1.077768012 ns   12.03 ps early
```

**3.9x, not 13.7x.** The 13.7x was arithmetic on an under-converged reference
that happened to sit 0.70 ps from espice's default. The verdict survives with
an enormous margin — espice's default is closer for any limit above
1.08222 ns, and the sequence brackets the limit in [1.08978, 1.08981] — but the
ratio must be quoted as ~4x on edge timing and ~5x on rms.

---

## 3. `ngspice/mosamp` — espice is the outlier (A and B agree)

Three-engine convergence at `tmax = 200 ps` (`d/mosamp_b.*`): esp-ng
1.687e-3 / 7.004e-5, esp-xy 2.965e-3 / 6.203e-5, ng-xy 2.545e-3 / 3.020e-5.
Common limit confirmed.

Defaults against it (reference grid `ng`@200p; the other two reference choices
move the numbers by <2 %):

```
Xyce    default:  9.14e-3 / 8.53e-4
ngspice default:  1.89e-2 / 1.76e-3
espice  default:  2.89e-2 / 2.54e-3
```

espice is last of three, 1.4x behind ngspice and 3.0x behind Xyce. This is
`fail-audit` §2's own conclusion (it measured ng 2.62e-3 vs esp 3.35e-3 against
a `tmax=2n` reference — same ordering, same ratio) and `ref-sims`'s. **No
conflict.** Mechanism as diagnosed in `fail-audit` §2: per-`ddt` LTE state
granularity, a VerA device-ABI item, unchanged here.

## 4. `devices/mos6_inverter` — espice is the outlier, and Xyce must recuse

espice and ngspice converge at `tmax = 1 ps`: 3.453e-4 / 1.816e-5. Defaults
against that limit:

```
ngspice default:  2.61e-2 / 1.20e-3
espice  default:  3.43e-2 / 2.13e-3      <- 1.8x looser
```

Reproduces `fail-audit` §3 (1.19e-3 / 2.15e-3) to three digits.

**Xyce does not converge to the same answer on this deck and cannot vote.** At
`tmax = 1 ps` Xyce is **2.276e-1 / 3.620e-2** from both of the others, while its
own grid-to-grid motion from 10 ps to 1 ps is only 1.740e-3 / 4.333e-5 — it is
converged, to a different limit. That is a model difference, not truncation.
`ref-sims`'s own table shows the same signature on `devices/mos6_simpleinv`
(espice-ngspice 6.27e-5, Xyce 3.67e-2) and applies exactly this reasoning to
`devices/jfet2` and `devices/mos9`. Xyce's level-6 MOSFET is not ngspice's
level-6 MOSFET, so Xyce's `FAIL 9.65e-2` on `mos6_inverter` is not corroboration
of anything — it would have read FAIL against ngspice too.

The verdict on the fixture is unchanged (espice 1.8x looser), because the two
engines that *do* share the model converge together.

## 5. `scaling/parallel_inverters_2000` — a tie, not an espice defect

All three converge at `tmax = 1 ps` (variables `v(in)`, `v(out1)`,
`v(out1000)`, `v(out2000)`, `i(vdd)`; the 2000 outputs are identical to
15 digits, and the full 766 MB raws are compared on this subset for memory):
esp-ng **9.649e-7 / 9.693e-9**, esp-xy 1.536e-5 / 5.709e-7.

Defaults against the limit — identical whichever engine's converged grid is the
reference:

```
espice  default:  4.10e-2 / 2.20e-3
ngspice default:  3.77e-2 / 2.24e-3
Xyce    default:  3.07e-3 / 2.53e-4
```

**espice and ngspice are equally wrong** (espice is 1.8 % *better* on rms, worse
on max — noise), and Xyce's default is 9x closer than either. `fail-audit` §4's
"tie" is correct. `ref-sims` lists this row under "Where espice is the outlier";
on the converged metric espice is not the outlier, the two trapezoidal engines
are jointly the outliers and Xyce is the one near the limit.

## 6. `vacask/mul` — espice marginally worse; the fixture defect does not block it

The `vacask/runme.sim` deck is a different topology from `circuit.sp`
(`ref-sims` documents it: `d1`, `d2`, `c3`, `d3`, `d4` all on different nodes),
so the VACASK column is unreadable, as B said. The ngspice/Xyce/espice column is
readable, and `circuit.sp` is the authority for it.

Run on a 10 µs window (`.tran 0.01u 10u 0 <tmax>`; the FAIL sample is at
4.6367 µs, so truncating `tstop` does not touch it) — all three converge at
`tmax = 100 ps`: esp-ng 4.929e-4 / 2.088e-6, esp-xy 6.775e-4 / 4.550e-6.

Defaults against the limit:

```
Xyce    default:  6.73e-3 / 2.34e-4
ngspice default:  2.41e-2 / 7.03e-4
espice  default:  2.15e-2 / 8.80e-4
```

espice is 1.25x worse than ngspice on rms and slightly better on max — a weak
result, consistent with `fail-audit` §5's "fixed grid phase, `tmax` pins the
step in both engines" and with `ref-sims` counting it as an espice row. Nothing
here is decisive either way, and the grid-phase mechanism `fail-audit` §5
identified is unaffected.

---

## Corrections on the record

### `docs/perf/ref-sims-2026-09-10.md` — two claims superseded

**Superseded: the `ensemble/pvt_corners` row of the "Where espice is the
outlier" table, and its lead sentence "Two independent references now agree
against espice on five of them."** On `pvt_corners` the two references do *not*
agree with each other: Xyce-vs-ngspice at default is 2.094e-1 / 4.559e-2, worse
than Xyce-vs-espice at 1.167e-1 / 3.015e-2. Scored against the three-way
converged limit, ngspice is the furthest of the three and espice is second.
The table's evidence is "espice failed both references", which on a deck where
*all three* pairwise comparisons fail the gate carries no information about who
is wrong. Cause: `comparePlots` is only ever called with espice as the
candidate, so the reference-vs-reference cell was never computed.

**Superseded: the `scaling/parallel_inverters_2000` row of the same table.**
Against the converged limit espice (2.20e-3 rms) and ngspice (2.24e-3) are
indistinguishable and Xyce (2.53e-4) is 9x better than both. Not an espice
outlier.

**Superseded: the "There is no fixture where ngspice is the outlier" heading.**
`ensemble/pvt_corners` is one, and `devices/hfet_inverter` is a second on the
two-engine instrument. The subordinate claim — that no *row of the PASS/FAIL
table* shows espice failing ngspice while passing a third reference — remains
literally true, and is the point: a 1e-3 binary gate cannot express "all three
disagree, and the reference is the worst of them".

**Standing, unaffected:** the Xyce/VACASK plumbing, the shim list, the refusal
tables, the `rc_ladder_*` integrator finding, `vacask/graetz` and `vacask/mul`
deck defects, `mos6_inverter` and `mosamp` as espice rows, and the two runner
defects fixed. The `rc_ladder` analysis is in fact load-bearing *for* this
arbitration — see below.

### `docs/perf/fail-audit-2026-09-10.md` — one number superseded, verdicts stand

**Superseded: §6's "espice's default grid times this edge 13.7x better than
ngspice's."** The reference used (`tmax = 2 ps`) had not converged; the limit
moves another 2.4 ps below it. Against the extrapolated limit (1.08980 ns) the
ratio is **3.9x** on edge timing and **5.2x** on full-trace rms. The verdict —
ngspice is the worse engine on `hfet_inverter` — stands with a large margin.

**Superseded, minor: §7's converged-reference numbers.** `tmax = 100 ps` is not
converged on this deck either; the `v(o2)` edge limit is 1.0048700 µs, not
1.004899669 µs. espice's default is therefore 3.0 ps *late*, not 26.6 ps early,
and ngspice's is 838.6 ps early, not 868 ps. The 3.5x rms ratio reproduces
almost exactly at the tighter grid (2.480e-4 vs 8.862e-4 = **3.57x**).

**Standing and now independently corroborated:** §7's rail-overshoot claim
(confirmed analytically and in both ngspice builds), §7's mechanism (ngspice
steps over the event), §2/§3's espice-defect verdicts, §4's tie, §5's grid-phase
diagnosis.

**Incomplete, not wrong:** §7 concludes "not a defect". Against the converged
limit espice's default is 9.5x further out than Xyce's. ngspice being worse does
not make espice right; `pvt_corners` is a fixture where espice's default step
control is measurably second-best, and nothing in `fail-audit` says so.

---

## How much weight Xyce carries, and why the answer differs per fixture

`ref-sims` weakened Xyce as a witness by showing that on the linear
`scaling/rc_ladder_*` decks it sits 8e-3 from a pair that agree to 2.2e-10, and
does not move when its tolerances are tightened 1000x. That is correct and it
matters here — but it cuts in a direction B did not take.

On a deck where **all three integrate the same model**, the espice-ngspice pair
is *not* two independent votes. They share a trapezoidal formula, so on the same
grid their errors are common-mode. This is visible directly on `pvt_corners`: at
`tmax = 100 ps` espice and ngspice agree with each other to 9.153e-3 / 4.884e-5,
yet each is 1.0e-1 / 1.9e-4 away from its **own** answer at `tmax = 10 ps`. Two
same-formula engines agreeing on one grid says nothing about how far that grid
is from the truth. Xyce's different integrator is exactly what makes its
agreement informative.

So the weighting rule this arbitration used, stated once:

- **Xyce is a strong witness where it converges to the same limit as the other
  two** — `pvt_corners` (4.6e-3 max at `tmax=10p`, still shrinking), `mosamp`,
  `mul`, `parallel_inverters_2000` (1.5e-5 at `tmax=1p`). There its default
  trace is a *fourth* datum: on all four it is the closest of the three to the
  limit, which is a fact about Xyce's step control, not about espice.
- **Xyce must recuse where it converges to a different limit** — `mos6_inverter`
  (2.3e-1 from both at `tmax=1p`, with its own grid motion 100x smaller), and
  the `rc_ladder`/`jfet2`/`mos9` group `ref-sims` already identified. A
  reference that is converged to a different answer is a different model or a
  different formula, and its default trace is evidence about nothing.
- The recusal test is mechanical and cheap: **tighten `tmax` until each engine
  stops moving, then compare limits.** It does not need a judgement call about
  integrators.

## What is not settled

- `vacask/mul` at 1.25x is inside the noise of the instrument. Reading it as
  "espice is worse" or "tie" both fit. The fixture also still has the
  `runme.sim` topology defect; that is `ref-sims`'s finding and is unfixed.
- The `hfet_inverter` limit rests on two trapezoidal engines. They converge
  together (9.2e-6 at `tmax=0.02p`) and the verdict survives a limit anywhere in
  [1.0822, ∞) ns while the Richardson sequence brackets it in
  [1.08978, 1.08981], so the conclusion is safe — but a genuinely independent
  third opinion does not exist for HFET decks in this tree and cannot be
  manufactured.
- **Not in doubt, and the one thing that needs no simulator:** a passive-loaded
  node with one capacitor to ground and no inductance cannot exceed its supply.
  ngspice's default trace does, by 156 mV, in both builds.

## Consequence for the harness

This does not change the recommendation in `fail-audit`'s closing section, it
sharpens it. Five of the seven FAILs are the comparator scoring espice's grid
phase against a reference whose own default trace is 1e-3 to 1e-2 rms from the
converged answer, and on two of them that reference is the worst of the three
engines available. Generating each transient reference at a tightened `tmax`
once, and scoring **every** engine against it, is the fix; `pvt_corners` is the
case that proves the current arrangement can invert a verdict.
