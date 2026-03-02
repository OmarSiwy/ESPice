# The measuring instrument, audited — 2026-09-13

Branch `measure-honest`, rebased onto `spice-audit` at **644ec3e**
(`merge: jac-op-width`). Nothing in `src/` changed: this is entirely about
`benchmark/`, which is the thing every performance and accuracy claim in this
repo is quoted out of.

Every number below was re-measured at 644ec3e. None was carried forward from the
earlier draft of this document — the Jacobian width went per-instantiation,
`.options tnom` was plumbed, `evalQ` stopped degrading under ParEval, rank-4
narrowing, PWL, limiting, `jac_rows`, and then five output-plumbing defects and a
fixture re-bias landed while this branch was in flight. Ratios measured against
any of those would be measuring a binary that no longer exists. `spice-audit`
moved three times during this work and the sweep was re-run each time; one
complete 290-fixture run was discarded mid-flight when `merge: out-plumbing`
landed, because it changed the columns the comparator reads.

**Two complete sweeps are reported**, at 537e89c and at 644ec3e — the only commit
between them is `jac-op-width`, whose own message says it "buys nothing". They
are kept side by side on purpose: they produce **identical verdicts** and
materially different timings, and that difference is the most useful measurement
in this document.

Four defects in the instrument, all of them in espice's favour:

1. **The speed headline included ngspice's dynamic linker.** On a 4 ms deck that
   is most of the reported difference.
2. **A quarter of the fixture suite could not be compared at all**, and an N/A
   reads like a pass in every summary.
3. **The runner could not compare two references to each other.** Every
   reference-vs-reference cell was structurally absent, and an absent cell reads
   as agreement. A published conclusion rested on that hole.
4. **The rig that made BJT decks profilable existed only in `/tmp`**, and `/tmp`
   had already been wiped once.

Sections 1–3 and 5 take those in order; §4 is the small-deck policy that §1's
correction forces, and §6 is what was deliberately left alone.

**The machine was busy throughout.** This box carries other agents; load average
ran 1.5–14 on 32 cores across the three sweeps this branch paid for. Every
wall-clock number here is stated with that caveat, and §1's A-vs-B comparison is
the honest measure of how well min-of-N and floor subtraction coped — the answer
is "well enough for the raw number, not well enough to pin the corrected one to
better than ~1.3x". Instruction counts and verdicts are load-independent and
carry no such caveat: the two runs agree on **every** PASS/FAIL/N/A/SKIP.

## 1. The startup floor

### The evidence

Callgrind, both binaries, the same two-device operating point, this host, at
644ec3e. Every figure reproduces across repeat runs:

| | espice | ngspice 44.2 |
|---|---:|---:|
| total instructions, whole process | **591,913** | **15,289,962** |
| of which `ld-linux-x86-64.so.2` | **233,541** | **9,814,699** |
| `do_lookup_x` | 66,052 | 4,924,802 |
| `_dl_lookup_symbol_x` | 39,066 | 2,249,041 |
| `_dl_relocate_object` | 40,856 | 1,625,590 |
| linker share of the process | 39.5% | **64.2%** |
| shared objects (`ldd`) | 3 | **23** |

espice's total is identical to the instruction across two runs (591,913 twice);
ngspice's ld.so total is identical too (9,814,699 twice) with its grand total
drifting by 1,457, or 0.01%. **ngspice's dynamic linking alone is 16.6x espice's
entire process floor**, and it is paid in full on a deck with two devices and no
analysis worth the name.

The cause is not a mystery. `ldd` on the ngspice binary lists `libXaw`,
`libXmu`, `libXt`, `libXext`, `libX11`, `libSM`, `libICE`, `libXpm`, `libxcb`,
`libXau`, `libXdmcp`, `libreadline`, `libncursesw`, `libgomp`, `libfftw3`,
`libstdc++`, `libuuid` — the entire X11 and GUI stack, relocated on every `-b`
batch run that will never open a window. espice links `libc`, `libm` and the
loader, and nothing else.

Two corrections to the record on the way:

- `docs/perf/slow-decks-2026-09-10.md` says espice "is statically linked". It is
  not. It links three objects and pays 233,541 instructions to do it. The gap is
  42x on the linker and 26x on the whole process, not infinite. That doc's
  headline of **10,229,999 Ir** was measured on a different deck; this one gives
  9,814,699 for the same set of functions. Both are ~10M, the finding stands,
  and the exact number is deck-dependent because the symbol count is.
- The earlier draft of this document put espice's linker cost at 313,037. Its
  three named function totals are identical to the ones above, so the difference
  is in the subtotal, not the measurement. The figure here is checked against
  `PROGRAM TOTALS`: with `--threshold=100`, `callgrind_annotate` lists 473
  functions summing to exactly 591,913, so 233,541 is the complete ld.so
  subtotal and not a truncated one.

### Why the correction is wall clock and not instructions

591,913 instructions do not take 3 ms. The wall-clock floor is dominated by
`fork`/`exec`, page-in of a 32 MB binary, and the runner's own `timeout` wrapper
process — kernel time that callgrind cannot see. Scaling a wall-clock ratio by an
instruction ratio would therefore be wrong in a second, independent way.

So the floor is measured the way the fixtures are measured: **the same deck, the
same statistic, the same harness path, in the same run**. The runner writes a
two-device `.op` deck, runs it through every timed binary before the sweep, and
records min and median for each.

This has a second benefit that was not the goal. The runner times espice through
`runCapture` (pipe, drain) and every reference through `runOk` (`.ignore`) — a
systematic asymmetry against espice that `slow-decks-2026-09-10.md` flagged and
nobody had priced. Because the floor is measured through the *same* path per
binary, that asymmetry is a constant per process and cancels in the subtraction.
So does the `timeout` wrapper.

### The correction must apply to both sides

Correcting only the reference would be the same sin inverted, and it is the more
tempting one because the reference's floor is the larger number. Every timed
column carries its own floor:

```
corrected = (ngspice_min - ngspice_floor_min) / (espice_min - espice_floor_min)
```

A column whose floor failed to measure gets **no** corrected ratio rather than
an uncorrected one wearing the corrected label. VACASK has no SPICE-syntax floor
deck and therefore no corrected column at all; it also feeds no ratio.

`RESULTS.md` prints `cpu/ng` (raw) and `cpu/ng*` (corrected) side by side, and
the same pair for the GPU column. **Neither is "the real number."** The raw
column overstates the simulator; the corrected column understates the program,
because ngspice's startup is real time that a real user really waits for. The
honest move is to print both and say which question each answers.

### The restated headline

Full sweep, 290 fixtures, `--iters 10`, pinned ngspice 44.2. Two complete runs,
**A** at 537e89c and **B** at 644ec3e, ~90 minutes apart, load average 1.5–5 on
32 cores throughout (other agents were building; B was the quieter of the two).
B is the shipped `benchmark/RESULTS.md`.

| | old claim | raw wall clock (A / B) | floor-corrected (A / B) |
|---|---|---|---|
| decks ranked | 225 | 237 / **237** | 100 / **52** |
| espice faster | 209 | 222 / **220** | 56 / **36** |
| geometric mean | — | 1.71x / **1.63x** | 1.23x / **1.59x** |
| arithmetic mean | **2.23x** | 2.00x / 1.93x | 2.27x / 3.38x |

Measured opening floor, run B: espice **3.25 ms**, ngspice **6.30 ms**,
Xyce 43.36 ms.

Five things to take from that table.

**The old headline is two different runs spliced together.** "209 of 225" is
from `docs/perf/baseline-3ref-2026-09-10.md`, whose own arithmetic mean is
**2.52x**. "2.23x" is from `docs/perf/baseline-446268a.md`, which records
**194** wins of 225, not 209. Recomputed from the committed tables:

| source | ranked | espice faster | arithmetic | geometric |
|---|---:|---:|---:|---:|
| `baseline-3ref-2026-09-10.md` | 225 | **209** | 2.523x | 2.064x |
| `baseline-446268a.md` | 225 | 194 | **2.229x** | 1.824x |

Neither table supports "209 of 225, mean 2.23x" as one measurement.

**The average was arithmetic.** An arithmetic mean of ratios is not symmetric
under swapping the numerator: a deck won 4x and a deck lost 4x average to 2.1x,
which reads as a win when the truth is parity. On the same raw wall clock the
geometric mean is **1.63x** against an arithmetic **1.93x**, and that gap is
before any floor correction at all. The corrected column shows the same pathology
far worse — arithmetic **3.38x** against geometric **1.59x** — because
subtracting a floor from a small deck inflates a handful of ratios without bound,
and an arithmetic mean is exactly the statistic that lets them dominate. If one
number has to be quoted, it is the geometric one.

**Most of the suite cannot be ranked once startup is removed.** 185 of the 237
ranked decks have less work left, after subtracting both floors, than the floor
measurement's own min-to-median spread. Those decks were never measuring the
simulator: a 4–5 ms espice run against a 7–9 ms ngspice run, both of which are
almost entirely process startup.

**On the decks that can be ranked, the margin is real but modest.** 1.59x
geometric, and **36 wins of 52** — a real edge, but on a seventh of the suite,
and see the next point before quoting it.

**The rankable population is itself a measurement, and it moved by 2x between
two runs of the same binary.** Run A ranked 100 decks and got 1.23x; run B ranked
52 and got 1.59x. Nothing about the engine changed. What changed is the floor
deck's own min-to-median jitter — 0.63 ms in A, **2.01 ms** in B — and the
ranking rule is written against that jitter, so a noisier floor draw admits fewer
decks and the survivors are the larger ones, which espice wins by more. **The
corrected geometric mean and the size of the set it is computed over are not
independent**, and any single corrected number quoted without its `n` is
meaningless.

### Uncertainty, and what can honestly be claimed

Three independent error bars, in increasing order of how much they should worry
anyone:

| | run A | run B |
|---|---|---|
| corrected, opening floor | 1.23x over 100 | **1.59x over 52** |
| corrected, closing floor | 1.18x over 79 | **1.57x over 56** |
| raw geometric | 1.71x over 237 | **1.63x over 237** |

The opening-to-closing spread **within** a run is small (1.23 → 1.18, 1.59 →
1.57). The spread **between** two runs of the same code is not (1.23 vs 1.59).
The raw number is the stable one: 1.63–1.71x across both runs, on the full
237-deck set, because it does not depend on a noise-threshold cut.

So the defensible statements are:

- **espice finishes first on 220 of 237 ranked decks, geometric mean 1.63x wall
  clock** (1.71x on the other run). True, reproducible, and what a user
  experiences — ngspice's startup is real time a real person really waits for.
- **Once each binary's process floor is removed, the simulation-only ratio is
  somewhere in 1.2–1.6x, on between 52 and 100 decks depending on how noisy the
  floor draw was.** espice is ahead on simulation work. By how much is not
  resolved to better than a factor of ~1.3 by this instrument on this machine,
  and the honest thing is to say so rather than pick the flattering run.
- **"2.23x faster" is not supportable in either reading**, and the count it is
  usually quoted with belongs to a different table.

**7 decks change winner between min-of-N and median-of-N** on the raw ratio in
run B (3 in run A) — the same count `slow-decks-2026-09-10.md` found by hand on
a `--iters 3` median and overturned with three independent methods. The runner
prints that number every run, so the size of the effect is never an argument.

## 2. The comparator

`docs/perf/na-audit-2026-09-10.md` itemised all 64 N/A fixtures by the exact
runner branch that fired, and ranked seven changes. The top two, worth 24
fixtures between them, are now in; a third fell out of running the result.

### Complex re/im comparison (branch C1)

`parseRawBlob` already read `Flags: complex` and already sized the buffer at
`2 * nvars * npoints`. `comparePlots` then refused the plot at a single `if`.

Each column is now two real series. Both are pushed through the **existing**
error path and the worse one is kept. Magnitude is deliberately not used: a
phase-convention error would read as a pass, and catching that is the only
reason an AC comparison exists. A complex plot against a real one is still
refused — that is two different analyses, not a comparison.

The regression test asserts exactly this: a candidate with re and im swapped has
identical magnitude at every point and must FAIL.

### By-name multi-plot matching (branch P5)

`parseRawBlob` returned one `Plot` and threw the whole file away if anything
followed it, which is every multi-analysis deck. It now returns every plot, and
a raw whose tail does not parse is still null, because a partially-read raw
silently drops an analysis.

Matching is **by name, never by index**. Plot order differs between the engines
on every multi-analysis deck: espice writes Operating Point first, ngspice
writes AC first. Index matching would score an AC sweep against an operating
point and call it a failure. Each candidate plot answers for at most one
reference plot, so a deck with two `.dc` legs cannot score both against the same
candidate.

Two asymmetries, both deliberate:

- A **reference** plot with no candidate counterpart is a coverage gap
  (`complete = false` → N/A), never a pass.
- A **candidate**-only plot is not. For `.four`, espice writes a
  `Fourier Analysis` plot into the raw where ngspice prints its table to stdout,
  and an extra analysis nobody asked to compare is not evidence of anything.

### Exact name first, class alias second

The first full sweep with the new matcher caught a defect in the matcher. The
class map exists so Xyce, which runs `.op` as a one-point DC sweep and labels it
"DC transfer characteristic", can answer for ngspice's "Operating Point". That
alias also makes those two names **interchangeable**, so on a deck where ngspice
writes both — a `.dc` leg and an `.op` — a single class-matching pass could pair
the sweep with the operating point and the operating point with the sweep. Point
counts then collide on both pairs, both are refused, and the fixture reads N/A.

`devices/jfet_vds_vgs` is exactly that deck, and the audit predicts
PASS 3.10e-6 / 2.17e-18 for it. The first run gave N/A with no numbers at all,
which is what sent me looking.

Matching is now two passes: exact lowercased plotname first, class only for
leftovers, and all pairing is resolved before any plot is scored so the exact
pass cannot lose a partner to the class pass. The Xyce alias still fires, in the
case it was written for — when there is no namesake.

This is the argument for running the thing rather than reading it. The by-name
change was correct and its test passed; the interaction with a pre-existing
alias was only visible on a real deck.

### `golden/temp` — already fixed, and left alone

The audit asked for ngspice's "exit 0, no raw written" case to read SKIP rather
than N/A. **A later agent already did this**, and better than the audit
proposed: `main` checks whether the raw is openable at the point where it is
still knowable and records `ran but wrote no raw`, and `refAccuracyStatus`
checks the skip reason *before* falling through to N/A. Verified on the fixture:
it reads SKIP with that reason printed under the row. No change was made.

### A bug the new tests found

Rolling the per-plot verdicts up exposed one: `compareRaws` could return
`pass = true` alongside `complete = false`. `accuracyStatus` renders that as N/A
so no published table was wrong, but any caller reading the field directly would
have seen a deck whose `.ac` leg matched and whose `.tran` leg had no
counterpart at all as a pass. Fixed to the same rule `comparePlots` already
applied within a single plot: an incomplete comparison cannot be a pass.

The pass rule itself is unchanged, and no per-fixture tolerance was added.

### Fixtures unlocked

Measured like for like, not predicted. The pre-change runner was built straight
out of git (`git show 6aa1468:benchmark/src/runner.zig`, single file, `std` only,
so `zig build-exe` compiles it standalone) and run against the **same engine
binary** and the same 290 fixtures at 644ec3e. Verdicts do not depend on machine
load or on iteration count, so this is an exact before/after and the engine
changes that landed mid-branch cancel out of both sides:

| | before | after |
|---|---:|---:|
| PASS | 168 | **202** |
| FAIL | 8 | **10** |
| N/A | **60** | **24** |
| SKIP | 24 | 24 |
| espice did not run | 30 | 30 |

**36 fixtures moved off N/A: 34 to PASS, 2 to FAIL. Nothing moved the other
way, and no fixture changed verdict for any other reason.** The Xyce column
moves the same way and is not counted above: N/A 32 → 5, PASS 126 → 150,
FAIL 23 → 26.

The load-independence is checked, not assumed: the `--iters 1` after-run above
and the `--iters 10` run that produced `benchmark/RESULTS.md` give **identical**
verdict counts on all three columns, across a stretch where the machine's load
average moved between 1.5 and 5.

Split by the change that unlocked it. This is not a guess — each fixture's
ngspice and espice raws were read and classified by shape:

| change | fixtures | which |
|---|---:|---|
| complex re/im alone | **20** | `ac/`×6, `adversarial/extreme_values`, `bjt/common_emitter`, `devices/{capacitor_ac,inductor_ac,urc_ac,diode_capacitance}`, `golden/ac`, `layout/coupled_ac`, `medium/ladder_filter`, `parser/ngspice_syntax`, `sweep/opamp_wl_{200,1000,5000}`, `convergence/ota_cutoff_abstol` |
| by-name multi-plot alone | **12** | `devices/{jfet_vds_vgs,vbic_noise_scale}`, `golden/{noise,four}`, `ngspice/rtlinv`, `noise/`×4, `fourier/`×3 |
| both changes needed | **4** | `ngspice/{lowpass_filter,res_array,res_partition,rca3040}` |

Two of those deserve naming:

- The four `fourier/` and `golden/four` fixtures are **candidate-side**
  multi-plot. ngspice writes one `Transient Analysis` plot; espice writes that
  plus a `Fourier Analysis (THD = …)` plot, because espice puts `.four` in the
  raw where ngspice prints it to stdout. The old parser returned null the moment
  anything followed the first plot, so an *extra* analysis on the candidate side
  discarded the whole comparison. The new rule — a reference plot with no
  counterpart is a gap, a candidate-only plot is not — is what those five rows
  are testing.
- `devices/jfet_vds_vgs` is the exact-name-first case, confirmed from the raws:
  ngspice writes `[DC transfer characteristic, Operating Point]` and espice
  writes `[Operating Point, DC transfer characteristic]` — reversed, and both
  names alias to the same class. A single class-matching pass pairs each with
  the wrong one. `na-audit-2026-09-10.md` predicts PASS for this fixture and it
  now reads PASS at 3.48e-7.

The two new FAILs are the point of the exercise — defects that were sitting
behind the word N/A:

| fixture | max | rms | what it is |
|---|---|---|---|
| `convergence/ota_cutoff_abstol` | 9.96e-1 | 7.96e-1 | the AC leg of the new convergence deck disagrees at full scale |
| `ngspice/rca3040` | 7.76e-3 | 4.51e-3 | the transient leg of a 3-plot deck |

`ngspice/rca3040` reproduces `na-audit-2026-09-10.md`'s predicted
**7.76e-3 / 4.51e-3 to every printed digit**, which is a useful check that the
new comparator computes the same arithmetic the audit replayed by hand.

The earlier draft of this document predicted five new FAILs, three of them on
`sweep/opamp_wl_*` and one on `ngspice/res_partition`. Those four are **PASS**
now, because `spice-audit` fixed them while this branch was in flight:
`merge: fixture-bias` re-biased the opamp decks (they were measuring the abstol
gate, not the circuit) and `merge: out-plumbing` implemented `ac=` on a
resistor. That is the comparator doing its job end to end — it stopped hiding
four defects, and they were fixed.

Total suite at 644ec3e: **202 PASS / 10 FAIL / 24 N/A / 24 SKIP**, plus 30
fixtures espice itself does not run (unsupported analysis — `.pss`, `.pz`,
`.stb`, `.trannoise` and friends), which the table marks `-` rather than
counting as anything.

## 3. The comparison the runner could not make

### The defect

`benchmark/src/runner.zig` called its comparator exactly one way:

```zig
res.cpu_accuracy.set(id, compareRawFiles(io, fxa, raw, zp_cpu_raw_path, cfg.rtol));
```

once per reference, **always with espice as the candidate**. The 4x4 matrix of
four engines has six unordered pairs; three of them involve espice and three do
not, and those three were never computed. Not "computed and found equal" —
never computed. In every summary this file has ever written, an absent cell
reads as agreement.

That is not a cosmetic gap. `docs/perf/ref-sims-2026-09-10.md` published:

> zero fixtures where espice disagrees with ngspice but agrees with another
> reference

and concluded from it that ngspice is with the majority everywhere, so espice is
the lone dissenter wherever it fails. The first statement is literally true and
is a statement about the runner's **rows**. The conclusion is a statement about
the runner's **cells**, and the cells that would decide it are the three the
runner cannot fill.

### What the missing cell says on `ensemble/pvt_corners`

Measured, this run, at 644ec3e:

| pair | rms | max | gate |
|---|---:|---:|---|
| ngspice vs Xyce | **4.559e-2** | 2.094e-1 | FAIL |
| Xyce vs espice | 3.015e-2 | 1.167e-1 | FAIL |
| ngspice vs espice | 9.471e-3 | 1.176e-1 | FAIL |

Xyce disagrees with ngspice **1.5x more** than it disagrees with espice. Every
pairwise comparison on this deck fails the gate. **There was no majority for
espice to be outside of**, and "espice is the lone dissenter" was an artifact of
the instrument, not an observation.

`docs/perf/pvt-arbitration-2026-09-10.md` reached the same conclusion with a
hand-built Python replica of the comparator, and the runner now reproduces its
table to three digits in both directions — 3.945e-3 rms with ngspice as
reference, 4.559e-2 with Xyce as reference. That agreement is the check that the
new code computes the same arithmetic the arbitration replayed by hand.

### Two things the implementation had to get right

**The comparator is directed.** `comparePlots(ref, cand)` uses the reference's
own peak and span as the error denominator and the reference's grid as the
sample points. The two directions of one pair are not the same number and on
`pvt_corners` they differ by more than 10x (3.945e-3 vs 4.559e-2). Picking one
direction per pair — say, always the alphabetically-first engine as reference —
would mean the six cells of one row use four different denominators and are not
comparable with each other, which is the only reason to compute them.

Each cell is therefore the **worse of both directions**. That is the same "worst
kept" rule `comparePlots` already applies across variables and `compareRaws`
across plots. It costs 12 directed comparisons per fixture instead of 6, but
each engine's raw is now parsed **once** and compared many times, so the sweep
does 4 parses per fixture where the espice-only row already did 6.

**An incomplete direction sets nothing.** espice writes more columns than Xyce
does, so the espice-as-reference direction comes back `complete = false` on most
Xyce pairs. Letting that decide the cell marked `devices/mos6_inverter` N/A on
exactly the two cells the matrix exists to show. An incomplete comparison is
neither agreement nor disagreement, so it does not set the verdict, does not
enter the outlier test at either end, and — importantly — still prints its
numbers under the `N/A`. Discarding the measurement along with the verdict is
how this got missed in the first place.

The espice PASS/FAIL columns in the main table are **unchanged** and still
directed. Nothing about this defect justifies restating them.

### Recusal: the shape, and why it is not a verdict

The matrix makes visible a reference that has converged to a different *model*
rather than a different *answer*: it sits far from every other engine while its
own grid-to-grid motion is small. `devices/mos6_inverter` is the worked case —
at `tmax=1p` Xyce is 2.3e-1 from both other engines with 100x smaller
self-motion, and at the deck's default grid this sweep measures it 2.34e-2 and
2.48e-2 from the other two while they sit 2.20e-3 from each other. A reference
in that position should recuse itself. With only the espice row computed it
silently counted as a vote.

`RESULTS.md` now carries a `furthest` column naming any engine whose every cell
is worse than every cell it does not appear in. **It is a pointer, not a
verdict**, and `ensemble/pvt_corners` is the proof: the column names Xyce there,
and the grid refinement in `pvt-arbitration-2026-09-10.md` shows Xyce is the
engine that is *right*. Confirming a recusal needs the engine's own grid-to-grid
motion, which is a second run per engine per deck and stays in the arbitration
harness. `furthestEngine` is never an input to `pass`.

### The matrix, measured

290 fixtures, 644ec3e. **36 fixtures are contested somewhere in the matrix; on
31 of them two REFERENCES disagree with each other.** Those 31 cells did not
exist before this branch. 29 of the 36 have one engine further from every other
than any of them are from each other:

| furthest engine | fixtures |
|---|---:|
| Xyce | 23 |
| espice | 2 |
| ngspice | **2** |
| VACASK | 2 |
| no outlier (all mutually at odds) | 7 |

Every row is in `benchmark/RESULTS.md` under "Pairwise matrix". The ones that
change a conclusion:

**ngspice is the outlier on two fixtures**, and `ref-sims-2026-09-10.md` says
that set is empty:

| fixture | ng/xy | ng/esp | xy/esp |
|---|---|---|---|
| `tline/ideal_tline` | **FAIL** 5.34e-3 | **FAIL** 1.16e-3 | 2.63e-15 |
| `tline/terminated` | **FAIL** 1.49e-3 | **FAIL** 7.04e-4 | 9.88e-16 |

espice and Xyce agree to **machine precision** on both — 2.6e-15 and 9.9e-16 —
and ngspice is the one that differs from both. Note the honest qualifier: the
*directed* published columns pass on these decks (espice-vs-ngspice 2.09e-17
with ngspice as reference), so this is not a published FAIL where espice
dissents. It is the undirected cell — the espice-as-reference direction, on
espice's own grid — that puts ngspice 1.16e-3 away from a pair that agrees to
1e-15. That is exactly the observation the espice-only row is structurally
incapable of making, and the reason to make it is that it exists.

**`ensemble/pvt_corners` is confirmed at full scale**, reproducing the
arbitration doc: ng/xy 4.56e-2, which is larger than xy/esp 3.02e-2 and much
larger than ng/esp 9.47e-3. No majority.

**espice is the outlier on two**, and the matrix says so as plainly as it says
the rest: `convergence/ota_cutoff_abstol` (2.07e1 from ngspice, 1.41e1 from
Xyce, while those two sit 2.76e0 apart) and `ngspice/mosamp` (5.82e-3 and
4.72e-3 against their 2.71e-3). The second reproduces the arbitration doc's
verdict that mosamp is an espice defect.

**VACASK is the outlier on two.** On `vacask/graetz` ngspice, Xyce and espice
agree with each other to 2.8e-5 or better and VACASK is 1.89e-1 from all three
— the cleanest recusal shape in the suite, and a fixture where the espice row
alone reports a bare `vc FAIL` with no way to tell whether the deck or the
reference is at fault.

**Xyce is the outlier on 23**, which is the number to be careful with. A single
engine accounting for two thirds of the outlier column is more likely to be a
systematic difference — Xyce's default timestep control and its internal-node
naming both differ — than 23 independent defects. This is precisely why
`furthest` is a pointer and not a verdict: the matrix identifies the engine to
investigate, and `pvt-arbitration-2026-09-10.md`'s grid refinement is what
decides whether it is wrong. On `pvt_corners` that refinement says Xyce is
*right*.

### The row-level claim survives; the conclusion does not

Measured at this tip, espice fails ngspice on **10** fixtures, and on none of
them does it pass a different reference. So `ref-sims-2026-09-10.md`'s literal
sentence — "zero fixtures where espice disagrees with ngspice but agrees with
another reference" — is **still true**, and this branch does not overturn it.

What this branch overturns is the inference. Of those 10, **9 also have Xyce
disagreeing with espice** and the **same 9 have Xyce disagreeing with
ngspice** — the tenth (`devices/hfet_inverter`) has no third reference at all,
because Xyce ships no HFET. A deck
where all three engines are mutually at odds tells you nothing about which one
is wrong, and a binary PASS/FAIL against a 1e-3 gate cannot express "all three
disagree, and the reference is the worst of them". The 26 contested fixtures
outside that set of 10 are disagreements between engines the old instrument
never compared at all.

The claim was about the runner's **rows**. The conclusion was about its
**cells**. The cells were absent.

## 4. The small-deck policy, confirmed

Three rules, and each one exists because a specific published number was wrong
without it.

### Minimum of N, not median

`docs/perf/slow-decks-2026-09-10.md` records **seven** decks reported as espice
regressions that three independent methods later overturned: callgrind
instruction counts, min-of-5 `user+sys` CPU time from `wait4` on a quiet
machine, and a re-run of the runner's own wall clock. All three said espice
wins. The seven:

| deck | as published | re-timed | espice Ir | ngspice Ir |
|---|---:|---:|---:|---:|
| `sweep/amp_bias_sweep` | 0.9x | **2.79x** | 4.95M | 19.99M |
| `tline/txl1_1_line` | 0.9x | **2.36x** | 13.62M | 31.01M |
| `ensemble/pvt_corners` | 0.9x | **1.67x** | 72.79M | 91.46M |
| `devices/lossy_tline` | 0.7x | **1.54x** | 69.00M | 97.29M |
| `devices/vbic_temp` | 0.6x | **1.47x** | 21.56M | 20.68M |
| `devices/bjt_npn_output` | 0.7x | **1.26x** | 51.07M | 44.02M |
| `devices/hfet_inverter` | 0.9x | **1.21x** | 45.27M | 43.05M |

Every deck in that table runs in **5–25 ms**, which is 1–5x the process floor.
The mechanism is not subtle: a simulator run is a fixed amount of work plus
whatever the scheduler and the other 31 cores did to it, and that contamination
is **one-sided**. The minimum is the sample that saw the least of it. The median
is not "typical" — it is typical *for the load that happened to be on the box*,
and the run that produced those seven rows was a `--iters 3` median on a loaded
machine.

The runner now reduces each batch two ways and keeps both: `min_ns` is the
headline, `p50_ns` sits beside it, and the summary reports **how many decks
change winner between the two**. That number is printed in `RESULTS.md` every
run, so the size of the effect is a measurement rather than an argument.

**Confirmed, and then confirmed again in a way that makes the point better than
intended.** Both full runs, min-of-10, same binary family, ~90 minutes apart:

| deck | raw A | raw B | corrected A | corrected B |
|---|---:|---:|---:|---:|
| `sweep/amp_bias_sweep` | 1.9x | 1.5x | 1.5x | *(unranked)* |
| `ensemble/pvt_corners` | 1.4x | 1.4x | 1.0x | 1.1x |
| `devices/lossy_tline` | 1.3x | **0.9x** | 0.9x | 0.6x |
| `tline/txl1_1_line` | 1.3x | **1.0x** | 0.5x | *(unranked)* |
| `devices/hfet_inverter` | 1.2x | 1.2x | 0.8x | 0.8x |
| `devices/vbic_temp` | 1.1x | 1.1x | *(unranked)* | *(unranked)* |
| `devices/bjt_npn_output` | 1.0x | 1.1x | 0.5x | *(unranked)* |

Read that table carefully, because it is the whole argument in one place.

**`devices/lossy_tline` reads 1.3x on one run and 0.9x on the other.** Same
engine, same reference, same deck, min of ten iterations each, on a box that was
*quieter* for the run that produced the worse number. A 13 ms deck cannot be
ranked from wall clock at this resolution, full stop — and that is with every
mitigation this branch added already applied. It is the single best argument for
the blank cell, and it only showed up because the sweep was run twice.

The `--iters 3` median called all seven **regressions**. They are not: six of
seven are ≥ 1.0x raw on both runs, and the seventh is the 13 ms coin toss above.
But the corrected column says espice does **more simulation work** on most of
them and still finishes first, because ngspice spends ~3 ms of every run in
`ld.so` before it reads the deck. `slow-decks-2026-09-10.md` reached the same
conclusion from instruction counts (`vbic_temp` 1.98, `hfet_inverter` 1.35,
`bjt_npn_output` 1.49 simulation-only Ir ratios against espice). Two independent
instruments, same answer: **both statements are true and they answer different
questions.** The instrument's job is to print both and refuse to pick.

**The policy, restated as a rule rather than a preference:** on this suite,
wall-clock ranking is trustworthy above roughly 25 ms and a coin toss below it.
The floor subtraction is what makes that boundary explicit instead of implicit,
and the blank cell is what stops the coin toss from being printed as a fact.

### Refusing to rank

Subtracting a floor from a deck that *is* the floor produces a ratio with no
information in it. The rule:

> A deck is ranked only when the work left after subtracting **both** floors
> exceeds the floor measurement's own min-to-median spread.

Below that, the `*` column is blank. Not 1.0x, not the raw number — blank. This
is deliberately the loud failure mode: a blank column is a question, a number is
an answer, and there is no answer there.

It costs a lot: **185 of 237 ranked decks** in run B (137 in run A), most of
`ac/`, `golden/`, `tf/`, `op/` and `parser/`. Those run in 4–5 ms against a
3.25 ms espice floor and a 6.30 ms ngspice floor, which means they measure
process startup and nothing else. That was always true; it was simply being
reported as a ~2x simulator speedup.

The cost is not fixed, and that is the rule working rather than failing: the cut
is against the floor's own jitter, so a noisier floor draw refuses more decks.
185 vs 137 between two runs of the same binary is the threshold correctly
tracking how well the machine could be measured that hour.

### The error bar

A wall-clock floor on a shared machine is a measurement, not a constant. So the
runner measures the floor **twice**: once before the sweep — used for every `*`
column, so no row is computed against a number that changed underneath it — and
once after. Re-deriving the corrected headline against the closing floor is the
error bar, and it is printed in `RESULTS.md` next to the headline itself.

### What is deliberately NOT done

No per-deck iteration count, no warm-up discard, no outlier rejection, no
tolerance that varies with deck size. Each of those would be a knob that makes
small decks look better, and the honest answer for a deck that is 90% process
startup is not a better-conditioned ratio — it is a blank cell.

## 5. The GFNI-free binary

### The problem

valgrind SIGILLs on this binary's `vgf2p8affineqb`, so callgrind could not
profile any deck reaching the BJT/VerA path — which is most of the interesting
ones. The working binary existed only at `/tmp/slowdeck/espice-nogfni`, and
`/tmp` had already been wiped once this session, taking a from-source ngspice
with it.

### The idiom, and why the patch is sound

The binary has ten `vgf2p8affineqb` sites. Six are the same shape:

```
vpacksswb / vpermq / vpshufd          ; bytes are now 0x00 or 0xFF
vgf2p8affineqb $0x0, <const>, %xmm, %xmm
vpmovmskb %xmm, %eax                  ; reads ONLY bit 7 of each byte
test $0x1ff, %eax                     ; 9, 10, 13, 13, 14, 22 lanes
```

That is LLVM lowering `@reduce(.Or, mask != 0)` for six different lane counts.
The constant is verified from `.rodata` rather than assumed: both the xmm sites
and the ymm site point at qwords of `01 00 00 00 00 00 00 00`. A GF(2) matrix
with one set bit, so the transform is `dst.bit[7] := src.bit[0]` and every other
bit is cleared — and `vpmovmskb` reads bit 7 and nothing else. On a `vpacksswb`
output, which is a saturated comparison mask with every byte 0x00 or 0xFF, bit 0
equals bit 7. The instruction is dead **with respect to its only consumer**.

A site is patched only if ALL of: imm8 is 0, the source is RIP-relative memory
whose qword is read from `.rodata` and equals a single set bit, the encoding is
10 bytes, a saturating pack is within the two preceding instructions, and the
next instruction is `vpmovmskb`.

The other four are correctly left alone, and the script says why for each: three
are a byte bit-reverse behind `vmovq`/`bswap` (register source, or not preceded
by a pack) and one is a string-compare mask fed by `vpxor`/`vpor`, where the
bit-0-equals-bit-7 precondition does not hold.

The replacement is the 10-byte canonical NOP `66 2e 0f 1f 84 00 00 00 00 00`,
exactly the length of the RIP-relative encoding it overwrites, so no address
moves and instruction *counts* stay comparable between the two builds.

### Reproducing it — the one line

```
zig build nogfni          # -> zig-out/bin/espice-nogfni
```

or `python3 benchmark/nogfni.py [--decks all] [--no-verify]`. It regenerates
from whatever `zig build` just produced; nothing is checked in but the script.

**Re-verified at 644ec3e, on the binary the per-model object split produced** —
the site count and the decision for each site are recomputed from the actual
machine code every run, not remembered:

```
10 vgf2p8affineqb sites
  keep  0x2a98574  source is a register, not the known constant
  keep  0x2a985b5  source is a register, not the known constant
  keep  0x2a98605  not preceded by vpacksswb; byte lanes are not 0x00/0xFF
  keep  0x2b2f66e  source is a register, not the known constant
  NOP   0x1e6373f 0x1fceafb 0x214c75b 0x26ae4ee 0x26dacb3 0x281421a
19 decks byte-identical
valgrind unpatched SIGILL=True / patched SIGILL=False
```

Ten found, six patched, four refused with a reason each, 19 decks byte-identical
on both the raw files and stdout, and the SIGILL asserted in both directions.
The `keep` reasons are worth reading: the script is not pattern-matching on
"looks like a reduce", it is checking the precondition that makes the patch a
no-op and declining when it does not hold.

The script **verifies both claims itself** rather than restating them:

- **Byte-identical output.** It runs 19 decks through both binaries and
  compares the raw files and stdout byte for byte. The first six are the ones
  that SIGILL; the rest spread across analyses and device families so a patch
  that broke a non-BJT path could not hide. `--decks all` runs every fixture.
- **The SIGILL itself.** It runs one BJT deck under valgrind with each binary
  and asserts the unpatched one dies and the patched one does not. If the
  unpatched binary stops SIGILLing it says so loudly — that means valgrind grew
  GFNI support or the codegen moved, and the patch may no longer be needed.

If either check fails the patched file is deleted and the tool exits non-zero,
so an unverified binary never exists under the name a profiling run would use.
If no patchable site is found at all it refuses rather than silently emitting an
unpatched copy, because a silently-unpatched binary is a profile that lies.

Profiling only. Nothing in the shipped build or in `zig build bench` ever runs
the patched copy.

## 6. Not fixed here

Engine defects get written up, not fixed. `na-audit-2026-09-10.md` section B2
listed eight. Five were fixed on `spice-audit` while this branch was in flight —
`merge: out-plumbing` closed reversed hierarchical node names, `.sp`
`portnum`/`z0`, one `i()` column per branch unknown, ordinal-keyed `.sens`
columns and `ac=` on a resistor, and `merge: noise-kinds` and
`merge: zero-analyses` closed `.noise` and `.disto`. The AC-excitation defect
stands. That is why the FAIL list in §2 is not the one the earlier draft of this
document predicted: the comparator stopped hiding those defects and the engine
then fixed most of them.

Runner changes 3–7 from that audit's ranked table (duplicate reference column
names, `.tf` column aliases, a wider internal-branch exemption, a relative
epsilon on the transient span guard) are not done. They are worth 13 more
fixtures between them and none of them is structural.

Two things this branch deliberately did NOT do:

- **The pass rule is unchanged and no per-fixture tolerance was added.** A
  failure is information. Some of the N/As this branch unlocked came back as
  FAILs (§2), and that is the point of the exercise, not a cost of it.
- **`furthestEngine` is never an input to a verdict.** It labels a table. An
  engine can be furthest from the other two and still be the one that is right
  — on `ensemble/pvt_corners` it is.

## Reproducing everything here

```
zig build && zig build test                              # 409/409 at 644ec3e
zig test benchmark/src/runner.zig                        # 19/19
zig build bench -- --iters 10 --out benchmark/RESULTS.md
zig build nogfni
```

References are pinned to nix store paths and their binary and version are
printed into `RESULTS.md` — a ratio against an unnamed "ngspice" is not
reproducible. The binaries behind every number in this document:

| role | version banner | binary |
|---|---|---|
| candidate | espice at `measure-honest`, tip `644ec3e` + 4 | `zig-out/bin/espice` |
| reference | `ngspice-44.2 : Circuit level simulation program` | `/nix/store/bywwgg84ccx0544z9qrfm4zc4ls30ghd-ngspice-44.2/bin/ngspice` |
| reference | `Xyce Release 7.10.0-opensource` | `/nix/store/7glhfffprbvfz11bi9pd1fr5np8nw5df-xyce-7.10.0/bin/Xyce` |
| reference | `This is vacask unknown.` | `/nix/store/g5ial84gcp2da9h7y63r4c6dc1iqip57-vacask-unstable-2026/bin/vacask` |

There is a second ngspice 44.2 on this host, built from source at
`/home/omare/Documents/Projects/Zig/ngspice-44.2-fromsource/bin/ngspice`. It
prints the *same* version banner and differs from the pinned build by a
deck-dependent **8.8–16.2%** in instruction count. It is **not** what produced
any number here. `pvt-arbitration-2026-09-10.md` established that the two builds
agree bit-for-bit on values and differ only in speed, so the 8.8–16.2% is a
performance fact and not an accuracy one — but it is exactly why the store path
is pinned and printed.

Callgrind floor measurements:

```
valgrind --tool=callgrind --callgrind-out-file=/tmp/fl.cg \
  zig-out/bin/espice -b --backend cpu -r /tmp/fl.raw zig-out/bench-out/floor.sp
callgrind_annotate --threshold=100 /tmp/fl.cg | grep ld-linux
```

With `--threshold=100` the listed functions sum exactly to `PROGRAM TOTALS`
(checked: 473 functions summing to 591,913 for espice, 1325 summing to
15,289,962 for ngspice), so the per-object subtotals in §1 are complete rather
than truncated.
