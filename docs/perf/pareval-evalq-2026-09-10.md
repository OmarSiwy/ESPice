# ParEval, re-measured with the `evalQ` handicap removed

`docs/perf/pareval-2026-09-10.md` closed with "ParEval never wins" and listed,
as a footnote, that `Circuit.evalQ` fell back to a full `eval` whenever ParEval
was live. That footnote was the measurement's own handicap: every transient MOS
deck in that sweep did 43.7% more full device passes on the threaded arm than on
the serial arm it was being compared against. This document fixes it and re-takes
the sweep.

## Verdict

**"Never wins" does not survive.** On the full 32-thread box,
`scaling/parallel_inverters_2000` now reaches **1.09–1.16× at 2 lanes**, in three
independent sweeps, against 0.99–1.02× for the same deck on the same box with the
old binary interleaved run-for-run. Pinned to the 16 E-cores it reaches **1.33× at
8 lanes**.

It still does not win *much*, and it still loses from 4 lanes up on the default
core mix. The Amdahl ceiling, refit on uncontaminated data, is **≈1.39×** — not
the 1.15× the old document computed, because that number was fitted through the
handicap.

Recommendation on the default is unchanged and is argued in the last section:
**keep ParEval opt-in, leave `default_min_instances` at 1024.** What changed is
the reason. It is no longer "threading never pays"; it is "threading pays about
15% at two lanes on one deck shape, and instance count still cannot tell that
deck shape from `rc_ladder_100k`, which loses 30% at the same width."

## Why `evalQ` degraded

`Circuit.evalQ` is the transient's post-accept charge re-read: `q_vec` and each
batch's `q_tape` at the accepted iterate, with g/c/rhs left alone, on a value-only
`S` (`engine.RealFor`) so it skips both Jacobians and the resistive residual. It
opened with

```zig
if (self.gpu_hook != null or self.par_eval != null) return self.eval(x, t);
```

and its docstring justified the ParEval half as "the paths whose accumulation this
cannot reproduce bit-for-bit … ParEval (per-lane slabs reduced in lane order)".

That reasoning inverts the contract. `evalQ` promises to leave in `q_vec` what
`eval` would have left there — and on a threaded run, `eval` *is* the lane-reduced
one. The bar is not "match the serial sum", it is "match the sum this path
produces". `ParEval` already owns a fixed partition (`tasks`/`task_off`, cut at
instance boundaries) and a fixed fold order (`reduce`, lanes 1..n ascending). A
charge-only mode that reuses both is bit-for-bit identical to `.full`'s q plane by
construction: same instances in the same lanes in the same order, same fold.

So the fallback was never a safety property. It was a stopgap, and the file said
so — the `ponytail:` note there already named the fix ("give ParEval a `.charge`
Mode if a threaded run ever leans on this"). Every transient run leans on it.

The GPU half of that condition is real and stays: `gpuEligible` devices compile
one fused kernel that produces all four planes, and there is no charge-only entry
point to call.

### What it cost, counted

Instrumented build, counters on `Circuit.eval` / `evalNewtonCpu` (full four-plane
passes) and `Circuit.evalQ` (charge-only passes). `ESPICE_THREADS=4`:

| deck | before (threaded) | after (threaded) = serial | Δ full passes |
|---|---|---|---:|
| `scaling/parallel_inverters_2000` | 1958 full, 0 charge | 1363 full, 595 charge | **+43.7%** |
| `scaling/parallel_inverters_500` | 1958 full, 0 charge | 1363 full, 595 charge | **+43.7%** |
| `scaling/parallel_inverters_100` | 1954 full, 0 charge | 1359 full, 595 charge | +43.8% |
| `devices/mos6_inverter` | 1252 full, 0 charge | 936 full, 316 charge | +33.8% |
| `scaling/rc_ladder_10k` | 473 full, 0 charge | 473 full, 0 charge | 0 |
| `scaling/rc_ladder_100k` | 473 full, 0 charge | 473 full, 0 charge | 0 |
| `scaling/resistor_grid_100x100` | 2 full | 2 full | 0 |
| `sweep/opamp_wl_5000` | 24 full | 24 full | 0 |

One correction to the old document while we are here. It attributed the shape of
its results to this defect — "the two decks that are not transient are the only two
that stay near 1.0×, and every transient deck loses". Half of that is wrong. The
`rc_ladder` decks *are* transient and were **never affected**: they have no
`has_state_q`, so `tran.zig` never calls `evalQ` at all. They lose for the reason
that document's own control 3 identified (plane traffic scaling with n), and this
fix does nothing for them. The defect only ever bit MOS transients — which happens
to be every deck where threading looked plausible.

`devices/mos6_inverter` is in the table for completeness only; at 2 instances it
never passes the 1024-instance gate, so it runs serial and was never affected in
a shipped configuration.

## The fix

Four commits' worth of change in one commit (`4f6d9f0`):

1. **`Hooks.eval_q` takes an instance range**, `(ctx, planes, first, last, x, t)`,
   like `eval` and `eval_newton`. It was whole-batch, which is why a lane could
   not call it. `abi_version` 7 → 8: `layoutHash`/`hashType` mix sizes,
   alignments and field offsets, and a function-pointer signature change moves
   none of the three, so the guard has to be the version number.
2. **`ParEval.Mode.charge`.** `runLane` clears only the q window on lanes ≥ 1 and
   dispatches `hooks.eval_q`; `reduce` folds only `q_vec`. The other three slabs
   keep whatever the last `.full`/`.newton` left, because nothing reads them back.
   `ParEval.evalQ` zeroes the caller's `q_vec` and forks.
3. **`Circuit.evalQ` routes ParEval to `p.evalQ`** and keeps the GPU fallback.
4. **`evalQOnly` forces `evalQRange` inline** — see below.

### The one non-obvious line

Making `first` a runtime value cost `devices/mos6_inverter` **0.91% of its total
Ir** for identical work: 145,338,851 → 146,659,379. Per-function attribution
shows mos6's charge core moving out of line, from a pair of ~420 kIr callees to a
single 1.67 MIr one. With the literal `0, self.count` LLVM had inlined
`evalQRange` into the shim; with a runtime start it stopped. `@call(.always_inline,
…)` restores the old shape and the old number (145,353,610, +0.010%). Same class
as the fused-stamp note already in `evalRange`: device-dependent codegen, not a
lever, but it has to be pinned or a serial deck pays for a threading fix.

### Two smaller defects, same area

**`@min(lanes, 16)`** at `src/engine.zig:318` is gone. `ESPICE_THREADS` is honoured
as asked; above `std.Thread.getCpuCount()` it clamps *and says so on stderr*. Every
"32 lanes" row in the previous document was a 16-lane row, which is why its 16 and
32 columns were byte-identical to each other. They are not identical any more, and
32 real lanes are much worse than 16 — see the table.

**The instance-boundary comment** (`src/devices/engine.zig:2160-2180`) said "no
instance's contributions ever straddle a lane" in a context that reads as a
per-node guarantee. It is per-instance: it keeps one instance's cancelling `+g/−g`
pair together, and says nothing about two instances of the same batch sharing a
node. `sweep/opamp_wl_5000`'s OTA #888 is the counterexample at 16 lanes and is now
named in the comment.

## The rig

- i9-14900HX. CPUs 0–15 are 8 P-cores with SMT (5.6–5.8 GHz), 16–31 are 16
  single-threaded E-cores (4.1 GHz).
- Binaries: `pareval-evalq` HEAD against a `git worktree` at the branch point
  `6aa1468`, both `zig build` ReleaseFast, both invoked as the benchmark runner
  does: `espice -b --backend cpu -r <raw> <deck>`.
- **Old and new are interleaved arm-for-arm in the same round-robin**, so the two
  binaries see the same drift. This is the main methodological change from the
  previous document, which compared against numbers taken hours apart.
- **The box was shared throughout.** Load average 8–28 (other agents' `zig`
  builds, `valgrind`, other simulator runs). Reported spread is 20–65% and that is
  contention: minima track medians and every sign below is the same on medians and
  on minima.
- 9–15 repeats per cell, round-robin over widths. Harness `/tmp/pq/ab.py` and
  `/tmp/pq/rawdiff.py` — one `subprocess` loop and one `struct.unpack`, not
  committed.
- **No Ir inside ParEval.** callgrind serializes threads, so the spin-then-yield
  barrier burns instructions that do not exist on hardware. Ir is used here only
  on the two serial guard decks.

## Scaling, new against old

Speedup is against each binary's own `ESPICE_THREADS=1`, which constructs no
`ParEval` (`lanes < 2` fails the gate) — the true serial path, not a one-lane
ParEval. `new/old` is the median ratio at that width: above 1.000 means the fix
made the threaded arm faster.

### `scaling/parallel_inverters_2000` — 6002 instances, n=2005, 596 tran points

Three sweeps. B ran at load 25, C at load 23, A is a new-binary-only spot check at
load ~18.

| T | old med (ms) | old sp | **new med (ms)** | **new sp** | new/old | A sp | B sp | new CPU (s) |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 955.9 | 1.000 | 936.5 | 1.000 | 1.021 | 1.000 | 1.000 | 0.93 |
| 2 | 939.5 | 1.017 | **807.2** | **1.160** | **1.164** | 1.116 | 1.094 | 1.58 |
| 4 | 1195.9 | 0.799 | 995.9 | 0.940 | 1.201 | 0.884 | 0.829 | 3.91 |
| 8 | 1249.8 | 0.765 | 1289.6 | 0.726 | 0.969 | 0.881 | 0.705 | 10.04 |
| 16 | 1869.4 | 0.511 | 1664.8 | 0.563 | 1.123 | 0.493 | 0.566 | 26.04 |
| 32 | 1869.8 | 0.511 | 4377.4 | 0.214 | 0.427 | 0.145 | 0.154 | 115.53 |

C: 15 repeats. B: 11. A: 3.

Read the `new/old` column and the T=32 row separately from the rest.

- **`new/old` at 2, 4 and 16 lanes is 1.12–1.20×.** That is the fix, measured
  directly, in wall clock, on interleaved runs. At 8 lanes it is inside the noise
  (0.969 here, 1.013 in sweep B).
- **The T=32 column is not a regression, it is the clamp coming off.** Old "32" was
  16 lanes and duplicates the 16 row exactly (1869.4 / 1869.8 ms). New "32" is 32
  real lanes: 32 runnable threads on 32 logical CPUs on a box already carrying load
  23. It collapses to 0.21×. The honest reading is that the previous document never
  measured 32 lanes and 32 lanes are bad.

### The other five decks

9 repeats each (5 for `rc_ladder_100k`), one sweep, load 25–28. Cell format
`new median / new speedup`, with the `new/old` ratio underneath in the last column
at the width where it is largest.

| deck | T=1 | T=2 | T=4 | T=8 | T=16 | T=32 |
|---|---:|---:|---:|---:|---:|---:|
| `parallel_inverters_500` (1502 inst, tran) | 206.1 ms | 197.3 / **1.045** | 242.6 / 0.850 | 267.9 / 0.769 | 396.7 / 0.520 | 3341.8 / 0.062 |
| `rc_ladder_10k` (20001 inst, tran, linear) | 249.9 ms | 359.1 / 0.696 | 334.9 / 0.746 | 502.1 / 0.498 | 571.6 / 0.437 | 1814.5 / 0.138 |
| `rc_ladder_100k` (200001 inst, tran, linear) | 2605.4 ms | 3587.2 / 0.726 | 3833.3 / 0.680 | 4807.1 / 0.542 | 6626.1 / 0.393 | 7837.8 / 0.332 |
| `resistor_grid_100x100` (**.op**) | 90.3 ms | 91.6 / 0.986 | 91.5 / 0.988 | 102.2 / 0.884 | 114.9 / 0.786 | 130.6 / 0.692 |
| `opamp_wl_5000` (25000 MOS1, **.ac**) | 750.0 ms | 806.6 / 0.930 | 814.6 / 0.921 | 852.1 / 0.880 | 1396.8 / 0.537 | 1820.0 / 0.412 |

`new/old` on these: `parallel_inverters_500` **1.16–1.26×** at 2/4/8/16 — the fix
again, same shape as the 2000 deck. The other four are 0.94–1.10, i.e. noise, which
is exactly what the pass-count table predicts: none of them calls `evalQ`.
(`opamp_wl_5000`'s 1.46 at T=8 is a single contended old-binary cell with 72%
spread; it does not reproduce in the ratio at any other width and there is no
mechanism for it.)

Serial medians are not comparable to the previous document's — the tree gained
`limit-body` (−6.95% on `parallel_inverters_100`), `dedup-delete` and
`ac-source-drive` in between, and `parallel_inverters_2000` serial is now 936 ms
against that document's 1300–1833 ms. The speedup columns are the comparable ones.

### Against the previous document's table, speedup for speedup

`parallel_inverters_2000`, best of the three sweeps in each document:

| T | old doc (best of A/B/C) | this doc (best of A/B/C) |
|---:|---:|---:|
| 2 | 1.071 | **1.160** |
| 4 | 0.864 | **0.940** |
| 8 | 0.915 | 0.881 |
| 16 | 0.760 | 0.566 |
| 32 | 0.738 (16 lanes) | 0.214 (32 lanes) |

The 8 and 16 rows are worse here than there, and the honest attribution is load,
not code: the `new/old` interleaved column says the fix is worth +12% at 16 lanes
on the same box in the same minute. Rows 2 and 4 are where the wins live and both
moved up.

## Controls

**1. E-cores, 16 of them, `taskset -c 16-31`.** The previous document's cleanest
result, re-taken with both binaries interleaved, 9 repeats, load 9:

| T | old med (ms) | old sp | new med (ms) | new sp | new/old |
|---:|---:|---:|---:|---:|---:|
| 1 | 1553.5 | 1.000 | 1535.8 | 1.000 | 1.012 |
| 2 | 1514.0 | 1.026 | 1259.2 | **1.220** | 1.202 |
| 4 | 1460.6 | 1.064 | 1247.2 | **1.231** | 1.171 |
| 8 | 1304.2 | 1.191 | 1151.7 | **1.333** | 1.132 |

Spread here is 2.8–12.1%, the tightest data in this document, because 16 E-cores
under load 9 are the least contended thing available. The sign flip the old
document found is confirmed and the magnitude goes up 13–20%.

**2. Eight distinct P-cores, no SMT sibling, `taskset -c 0,2,4,6,8,10,12,14`**,
9 repeats, load 10:

| T | old sp | new sp | new/old |
|---:|---:|---:|---:|
| 1 | 1.000 | 1.000 | 0.996 |
| 2 | 1.031 | **1.179** | 1.140 |
| 4 | 0.827 | 0.976 | 1.177 |
| 8 | 0.606 | 0.573 | 0.943 |

The old document's control 1 concluded "perfect placement does not save it"
(0.86/0.82/0.82). With the handicap gone, 2 lanes win and 4 break even. 8 lanes on
8 pinned cores against external load 10 is not a measurement of anything (48%
spread).

**3. Amdahl, refit.** The old document solved backwards from 1.071× at 2 lanes and
got f ≈ 0.13, ceiling 1.15×. That fit was invalid: the T=2 arm did 43.7% more full
device passes than the T=1 arm it was divided by, so the fitted f absorbed the
extra work. Refitting on arms that do identical work:

| source | S | T | f | ceiling |
|---|---:|---:|---:|---:|
| all cores, T=2 | 1.160 | 2 | 0.276 | 1.38× |
| 16 E-cores, T=8 | 1.333 | 8 | 0.286 | 1.40× |

Two independent points, different core types, different widths, agreeing on
f ≈ 0.28. **The real parallel fraction of `parallel_inverters_2000` is twice what
the previous document computed, and its ceiling is ≈1.39×.** The E-core arm reaches
1.333× — 96% of that ceiling. ParEval is not far from what it can deliver on this
deck; the deck is what limits it. LU factor, triangular solve, `stepBound`,
`updateStates`, the timestep controller and 9.6 MB of waveform output are all
serial.

## Correctness

Three repeats per (deck, width) at widths 2/4/8/16/32, md5 of the raw file, plus a
full-precision word-by-word comparison against `ESPICE_THREADS=1`. **90 runs, one
unique md5 per cell, 30 cells.** Run-to-run determinism holds at every width on
every deck, including the 32 lanes that were never actually exercised before.

| deck | vs serial |
|---|---|
| `rc_ladder_10k` | **bit-identical at 2/4/8/16/32** |
| `rc_ladder_100k` | **bit-identical at 2/4/8/16/32** |
| `opamp_wl_5000` | **bit-identical at 2/4/8 and 32**; 613 of 2731638 words at 16, `max_abs` 6.5e-09 |
| `resistor_grid_100x100` | 163–1332 of 10002 words, `max_abs` 4.441e-16, `max_rel` 2.217e-16 at every width |
| `parallel_inverters_500` | 226→596 of 300980 words; `max_abs` 1.4e-17 (T=2) → 1.2e-15 (T=32) |
| `parallel_inverters_2000` | 163→596 of 1194980 words; `max_abs` 1.4e-17 (T=2) → 2.3e-14 (T=32) |

Every deviation is last-ulp reassociation. The two ladders are bit-identical
because each stage's stamps land wholly inside one lane. The numbers reproduce the
previous document's table cell for cell where they overlap, so the `.charge` mode
introduced no new divergence class — which is the claim that mattered, since a
charge pass that reduced in a different order from `.full` would have shown up here
as a new deviation set on the MOS transients, and it does not.

`opamp_wl_5000` diverging at 16 lanes but not at 32 is the OTA #888 effect from the
previous document: whether a node's drivers straddle a lane cut depends on where
the cuts fall, and 32 cuts happen to miss. `max_rel` 2 at T=16 is again a fully
cancelled AC real part, `max_abs` 6.5e-09 against a column max of 2e+07.

## No serial regression

`zig build test` **406/406** (the branch point reports the same). `zig build
test-fixtures` 22/24 + 1 unsupported, with the one failure `golden/qpss:
QpssDidNotConverge` identical on `6aa1468`.

Ir, serial path (no `ESPICE_THREADS`), callgrind, against the branch point:

| deck | 6aa1468 | this branch | Δ |
|---|---:|---:|---:|
| `scaling/parallel_inverters_100` | 433,935,826 | 433,919,016 | **−0.004%** |
| `devices/mos6_inverter` | 145,338,851 | 145,353,610 | **+0.010%** |

## Recommendation on the default

**Keep ParEval opt-in. Leave `default_min_instances` at 1024.** The conclusion is
the same as the previous document's; the argument is not.

That document's argument was "threading never pays, so no threshold is worth
tuning". That is no longer true — at 2 lanes it pays 16% on
`parallel_inverters_2000` and 4.5% on `parallel_inverters_500`, and on E-cores it
pays 33% at 8 lanes.

The argument that survives is the second half of it, and it is now the whole
argument: **instance count cannot distinguish the decks that win from the decks
that lose.** At the width where threading is best (T=2):

| deck | instances | T=2 speedup |
|---|---:|---:|
| `parallel_inverters_2000` | 6002 | **1.160** |
| `parallel_inverters_500` | 1502 | **1.045** |
| `rc_ladder_10k` | 20001 | 0.696 |
| `rc_ladder_100k` | 200001 | 0.726 |

`rc_ladder_100k` has 33× the instances of the best deck and loses 27%. Any
threshold on instance count that turns threading on for `parallel_inverters_2000`
turns it on for both ladders. The gate as written is correct by accident, and the
accident is load-bearing.

**What the right gate would observe.** Not instance count — *nonlinear device-eval
work as a fraction of estimated per-iteration cost*. The separating variable is
visible in the corpus: the two winners are nonlinear MOS transients where the
device kernel is most of the iteration; the two losers are linear R/C ladders where
device eval is trivial and the per-eval plane traffic (which scales with n, per the
previous document's control 3) is everything. `sum(count × n_u²)` will not see it —
that weight is 800004 for `rc_ladder_100k` (200001 instances at n_u=2) against
≈264000 for `parallel_inverters_2000` (4000 mos1 at n_u=8 plus 2000 caps at
n_u=2), i.e. it ranks them backwards, because it treats a resistor stamp and a
mos1 Jacobian as the same work.

A gate that would work needs a per-device-type eval cost. The cheapest proxy is
already in the tree and costs nothing to read: `Batch.has_const_jacobian`, the flag
`computeBaseline` uses to decide what folds into `g_base`. It is false for exactly
the nonlinear batches — mos1 in both winners, true for every R and C in both
losers. The shape would be
`nonlinear_weight / (nonlinear_weight + c·nnz) > τ` with τ ≈ 0.5 and `c`
calibrated once. **Not built.** It is a cost model with one tuning
constant, justified by a 16% win at exactly one width on exactly two decks of one
corpus, and the honest next step is a deck whose parallel fraction exceeds ~0.6 —
none exists here — not a heuristic fitted to f ≈ 0.28.

**Two operational notes for anyone who does opt in.**

- **Use 2 lanes, maybe 4.** On this corpus the win is at T=2 and it is gone by
  T=8 on every deck. The old advice to try wide widths came from rows that were
  measuring 16 lanes while claiming 32.
- **32 lanes are actively harmful**, 0.21× on `parallel_inverters_2000`. The
  `@min(lanes,16)` clamp was hiding this rather than preventing it; the cause is
  the previous document's control 4 (the 4096-spin `std.Thread.yield()` barrier
  thrashing at full subscription), and it is worse at 32 than at 16 for the same
  reason. Fixing the barrier is the prerequisite for any width above 8 being
  worth measuring, and it is orthogonal to everything in this document.

## What changed

`src/analysis/Circuit.zig`, `src/devices/engine.zig`, `src/engine.zig`; one
commit. `zig build test` 406/406, serial Ir flat to ±0.01%, determinism verified
at 2/4/8/16/32 across 90 runs.
