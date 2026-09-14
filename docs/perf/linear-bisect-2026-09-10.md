# The linear-deck +2% at `446268a` — bisect, and where it actually came from

Chasing the note left in `remaining-2026-09-10.md` under "Where the numbers
stand": `scaling/rc_chain_500` went 79,097,457 → 80,589,126 Ir (+1.9%) and
`scaling/rc_ladder_10k` 1,178,022,498 → 1,203,408,608 (+2.2%) across
`6e55e74` → `446268a`, while `parallel_inverters_100` and `devices/mos6_inverter`
moved +0.17%. The note blamed the 18-way audit's safe-cleanup pass over 60 files
under `src/`, and said so was not chased.

**Result: the espice-side cleanup is not the cause.** Reverting every hunk of
`446268a` that still applies — 52 of its 60 `src/` files, in two halves —
recovers nothing on either linear deck. And the delta is not linear-deck-shaped
at all: all four decks paid the *same* ~5.5 Ir per matrix row per Newton
iterate. The linear decks only look worse because they have no MOSFET work to
dilute it. The one thing that moved alongside `446268a` and is uniform per row
per iterate is the code generator: `../VerA` went `baccc5a` → `a19b6fb` in the
same instant, and `a19b6fb` is VerA's own parallel-audit checkpoint, 1063 lines
of it in `src/ir/lower.zig`.

No revert is proposed. Nothing was found on the espice side worth reverting.

## Method

`espice -b --backend cpu -r RAW DECK` under `valgrind --tool=callgrind`, Ir off
the `summary:` line. Deterministic, so single runs, no medians. Every number
below is one command shape on one binary; each experiment is a real
`zig build`, not an ablation (hazard 4 in `remaining-2026-09-10.md` — the
gate-a-pass-twice trick is invalid for codegen questions, and this is one).

`-Ddebug-info=true` still SEGVs the Zig 0.16 compiler (tried; it does), so the
binary is stripped and callgrind prints entry addresses. Attribution below is by
call count and call-graph shape, as in the existing budget.

**Rig hazard, new one.** The `zig-out/bin/espice` that came with this worktree's
pre-seeded `.zig-cache` was NOT the binary a clean `zig build` produces from the
same tree: `zig build` reported it up to date, but it reads `mos6_inverter` 0.9%
higher (146,649,034 vs 145,343,554) and `rc_chain_500` 863 Ir lower. Every
baseline here is a from-source rebuild, and the first comparison made against
the seeded binary produced a phantom 0.92% "win" that vanished on rebaselining.
Rebuild the baseline; do not trust a seeded `zig-out`.

## The regression still reproduces on the current tip

| deck | `6e55e74` | `446268a` | tip (`6aa1468`) | tip vs `446268a` |
|---|---:|---:|---:|---:|
| `scaling/rc_chain_500` | 79,097,457 | 80,589,126 | **80,613,032** | +0.03% |
| `scaling/rc_ladder_10k` | 1,178,022,498 | 1,203,408,608 | **1,203,645,503** | +0.02% |
| `scaling/parallel_inverters_100` | 465,576,835 | 466,358,473 | **433,937,144** | −6.95% |
| `devices/mos6_inverter` | 153,490,575 | 153,737,019 | **145,343,554** | −5.46% |

Nothing since `446268a` has touched the linear decks — six merges, +0.03%. The
MOSFET decks moved because `limit-body` landed. So whatever was paid at
`446268a` is still being paid, and reverting it at tip is a valid experiment.

`6e55e74` cannot be built in this worktree: its `src/devices/loader.zig`
references `engine.LoadedDevice`, which its own `src/devices/engine.zig` does
not define, and the path deps `../VerA` / `../gompute` have moved a long way
past it. So there is no baseline binary; the bisect is within the diff, at tip.

## The bisect

`git diff 6e55e74 446268a -- src` is 60 `.zig` files. 53 of them reverse-apply
cleanly at tip; the 7 that do not are `builder.zig`, `tran/matex.zig`,
`dc/dc.zig`, `dc/dcmatch.zig`, `post/four.zig`, `sweep/mc.zig`, `sweep/sens.zig`
— all setup- or analysis-path, none on the per-iterate path. `devices/loader.zig`
reverse-applies but does not compile at tip (same `LoadedDevice` break), so 52
files were actually testable.

Split in two and measured. Numbers are the reverted build; the delta column is
against the tip baseline above.

### Group A — 16 files on the transient/solver/frontend hot path

`analysis/Circuit.zig`, `analysis/tran/tran.zig`, `analysis/tran/types.zig`,
`analysis/types.zig`, `analysis/root.zig`, `solvers/{direct,order,tridiag,types,newton_core}.zig`,
`frontend/{parser,tokenizer,types,source}.zig`, `output/{rawfile,ascii_raw}.zig`.

(`Waveform.toRows` was kept at its `446268a` form so `matex.zig`, which is not
revertible, still compiles; `tran.run` uses the reverted untiled loop.)

| deck | reverted | vs tip |
|---|---:|---:|
| `rc_chain_500` | 80,920,910 | **+0.38%** |
| `rc_ladder_10k` | 1,209,068,799 | **+0.45%** |
| `parallel_inverters_100` | 527,130,252 | +21.48% |
| `mos6_inverter` | 169,890,545 | +16.89% |

Reverting group A makes the linear decks *worse*, not better. The MOSFET decks
blow up by 16–21% because the revert takes out `Circuit.evalQ` and puts the full
post-accept `Circuit.eval` back — that one is a large, correct win and the
linear decks do not see it (`has_state_q` is false for the R/C/V set, so the
post-accept re-read never runs).

### Group B — the other 36 revertible files

`analysis/{ac/*,dc/op,dc/tf,eigen/pz,post/disto,pss/*,sweep/lanes,sweep/temp_sweep,tran/envelope,tran/tran_noise}.zig`,
`devices/{coupled_ltra,kernels,ltra_native,txl_native}.zig`, `gpu_context.zig`,
`output/{citifile,csv,fsdb,psf,spice_print,sst2,touchstone}.zig`,
`solvers/{bbd,dense_lu,dev_harness,freq_solve,gmres,lane_lu,preconditioner}.zig`.

| deck | reverted | vs tip |
|---|---:|---:|
| `rc_chain_500` | 80,574,451 | −0.05% |
| `rc_ladder_10k` | 1,203,195,454 | −0.04% |
| `parallel_inverters_100` | 433,844,058 | −0.02% |
| `mos6_inverter` | 145,303,297 | −0.03% |

Flat on all four — every row inside ±0.05%, which is where "no code on this
deck's path changed" lands.

A + B covers every `446268a` hunk that still exists at tip. Neither half
contains a −1.9% for the linear decks, and they are close enough to additive
that no interaction between them can hide one.

### Individually ruled out along the way

- **`Waveform.toRows` 32×32 tiling** (`analysis/tran/types.zig:105`). The prime
  suspect on shape — O(points × probes), and justified in its own comment with a
  *wall-clock* number (1.85 s vs 1.97 s on `rc_ladder_100k`), which is exactly
  how a cache win that costs instructions gets in. Replaced with the untiled
  point-major loop it superseded and rebuilt: `rc_ladder_10k` 1,203,644,796 vs
  1,203,645,503 (**−707 Ir, −0.00006%**), `rc_chain_500` 80,612,207 vs
  80,613,032 (−825 Ir, −0.001%). Three and a half orders of magnitude short of
  the regression. The tiling stays: it is a measured wall-clock win on the big
  ladders and it costs essentially nothing in instructions.
- **`solvers/order.zig:358`** `std.math.sqrt(n)` replacing the counting loop:
  both are exactly `floor(sqrt n)` (checked at n = 3, 4), so `dense_thresh` and
  the AMD ordering are unchanged — and AMD does not run for either linear deck
  anyway, `SolverT.init` returns on the `isTridiag` branch before
  `computeOrdering`.
- **`solvers/tridiag.zig:118`** dropping `self.mul[0] = 0`: `mul[0]` is never
  read — `factor`, `solve` and `solveT` all index `mul` from 1.
- **`solvers/direct.zig:252`** hoisting the `solveT` in-place memcpy above the
  branch: same single memcpy on every arm, and `solveT` is not on the transient
  path.
- **`Circuit.combineGCAndClear` deletion**: the surviving `combineGC` is the old
  `combineGCInner(..., clear=false)` specialization verbatim; the clear arm had
  no live caller.
- **`std.mem.swap([]f64, &cur, &trial)`** (`tran.zig:653`): O(1), ~600 calls.
- **Parse/tokenize**: the deltas do not fit a per-netlist-line model. Fitting
  `delta = c·lines + b·(n · iterates)` to the two RC decks gives **c = −128**;
  the netlist-size term is negative, i.e. absent.

## What the delta actually is

The four before/after pairs in `remaining-2026-09-10.md` are enough to fit the
shape, using the iterate and row counts the same document records for the
MOSFET decks and callgrind call counts for the linear ones (`rc_chain_500`:
544 Newton iterates over 272 accepted points, n = 502; `rc_ladder_10k`: 474 over
236, n = 10002).

| deck | Δ Ir | n | NR iterates | **Δ per row per iterate** |
|---|---:|---:|---:|---:|
| `rc_ladder_10k` | 25,386,110 | 10,002 | 474 | **5.36** |
| `rc_chain_500` | 1,491,669 | 502 | 544 | **5.46** |
| `parallel_inverters_100` | 781,638 | 105 | 1,358 | **5.48** |
| `mos6_inverter` | 246,444 | 45 | 935 | **5.86** |

Four decks spanning 222× in total Ir and 222× in n, agreeing to within 9% on one
number. Competing models are all worse: per accepted timestep varies 5× across
the four, per device evaluation varies 1.7× (2.68 / 2.74 / 1.91 / 3.29), per
netlist line is contradicted outright.

**So the premise in the original note is wrong.** This is not "a cleanup
deoptimised a hot loop in the solver or the transient driver, which is why the
decks with the least device work pay". Every deck paid the same per-row tax; the
linear decks paid a bigger *fraction* of a smaller total. `parallel_inverters_100`
also tells us the trajectory did not move — the budget records 595 accepted
points and 1352 transient NR iterates both before and after — so this is real
per-iterate work, not extra timesteps.

For the record, the per-point decomposition of `rc_chain_500` at tip (same deck,
`.tran 5u 1m` → 272 points vs `.tran 5u 10u` → 71 points, differenced):

- 267,900 Ir per accepted point, ~7.8 M fixed (parse + build + OP + output).
- Per Newton iterate, n = 502: solve 51 Ir/row, convergence test 32, the
  limiting/update pass 26, plane zeroing 26, newton-loop self 11, assemble +
  `evalNewton` self 12, and the two device batches (500 resistors, 500 caps)
  46 and 38 Ir per instance.

A uniform +5.5 Ir/row/iterate is ~2.5% of that ladder, spread across it.

## Where it came from

`446268a` was not committed alone. `../VerA` `a19b6fb` — "checkpoint:
in-progress ddt-capform working tree" — is timestamped `13:27:56`, six seconds
after `446268a`'s `13:27:50`, and is VerA's half of the *same* 18-way parallel
audit. `remaining-2026-09-10.md` says so in its own words: the re-measurement was
taken "on 446268a + VerA a19b6fb".

The `6e55e74` numbers were taken at VerA `baccc5a` (that document credits the
prefix-latch, which is `baccc5a`, as already landed). `baccc5a` is `a19b6fb`'s
parent. So **VerA moved by exactly one commit between the two espice
measurements**, and that commit is:

```
 src/ir/lower.zig       | 1063 +++++++++++++++-------------------
 src/frontend/parser.zig |  408 ++++++----------
 src/ir/elaborate.zig    |  377 +++++++--------
 src/ir/proof.zig        |  199 ++------
 ... 32 files
```

`lower.zig` and `elaborate.zig` are the Verilog-A → Zig lowering. Every device
kernel in the binary is their output, and the scatter/stamp they emit runs once
per instance per Newton iterate — which is the only axis in this system that is
uniform per row per iterate across a 500-resistor chain, a 10k-node ladder and a
200-MOSFET inverter bank alike.

This is not proven by measurement: espice tip requires VerA ≥ `a5da976`
(`jac_rows`), so it cannot be rebuilt against `baccc5a`, and `../VerA` is shared
with the other worktrees, so it was not checked out. It is the only remaining
explanation after 52 of 60 espice files were reverted with no effect, and it
matches the shape exactly.

**Correction to `remaining-2026-09-10.md`:** the +1.9% / +2.2% is attributed
there to `446268a`'s 60-file cleanup. That attribution does not survive a
revert. It should read "446268a + VerA a19b6fb", and the VerA half is the
likelier owner.

## Files

- Bisect groups: `/tmp` only, reproduce with
  `xargs -a LIST git diff 6e55e74 446268a -- > p.patch && git apply -R p.patch`.
- Decks: `benchmark/fixtures/scaling/{rc_chain_500,rc_ladder_10k,parallel_inverters_100}`,
  `benchmark/fixtures/devices/mos6_inverter`.
