# The 16 slow decks — families, mechanisms, ranked fixes

2026-09-10, HEAD 446268a. Follow-on to `docs/perf/baseline-446268a.md`, which
listed 16 decks where espice is slower than ngspice 44.2. Method follows
`docs/device-eval-vs-ngspice-2026-09.md`: callgrind instruction counts, both
engines, same deck, attribution by call count and ablation.

Reference binary throughout: the runner's pinned
`/nix/store/bywwgg84ccx0544z9qrfm4zc4ls30ghd-ngspice-44.2/bin/ngspice`.

## Headline

**Seven of the sixteen rows do not reproduce.** Three independent methods
(callgrind Ir, min-of-5 CPU time on a quiet machine, and a re-run of the
runner's own median-of-10 wall clock) all say espice *wins* those decks. The
real population is nine, and it has two mechanisms, not four:

| # | deck | ng/zp re-timed | espice Ir / ngspice Ir | family |
|---|---|---:|---:|---|
| 1 | `devices/hisim2` | 0.29x | ~3.5 (est.) | DC-sweep compact model |
| 2 | `tran/fourbitadder` | 0.37x | 2.13 | BJT kernel, transient |
| 3 | `bypass/burst_clock` | 0.49x | 2.29 | **PWL source** |
| 4 | `ngspice/schmitt` | 0.58x | 1.67 | BJT kernel, transient |
| 5 | `devices/vbic_output` | 0.64x | 2.26 | DC-sweep compact model |
| 6 | `devices/hicum2_output` | 0.67x | 1.18 | DC-sweep compact model |
| 7 | `ngspice/rca3040` | 0.72x | 1.83 | BJT kernel + DC-sweep leg |
| 8 | `ngspice/fourbitadder` | 0.73x | 2.13 | same deck as #2 |
| 9 | `devices/mos6_inverter` | 0.95x | 0.92 | already known, already even |

Not reproducible — espice is faster on all three metrics:

| deck | RESULTS.md | re-timed ng/zp | zp Ir | ng Ir | zp CPU | ng CPU |
|---|---:|---:|---:|---:|---:|---:|
| `sweep/amp_bias_sweep` | 0.9x | **2.79x** | 4.95M | 19.99M | 3 ms | 9 ms |
| `tline/txl1_1_line` | 0.9x | **2.36x** | 13.62M | 31.01M | 5 ms | 10 ms |
| `ensemble/pvt_corners` | 0.9x | **1.67x** | 72.79M | 91.46M | 11 ms | 17 ms |
| `devices/lossy_tline` | 0.7x | **1.54x** | 69.00M | 97.29M | 10 ms | 17 ms |
| `devices/vbic_temp` | 0.6x | **1.47x** | 21.56M | 20.68M | 6 ms | 8 ms |
| `devices/bjt_npn_output` | 0.7x | **1.26x** | 51.07M | 44.02M | 10 ms | 13 ms |
| `devices/hfet_inverter` | 0.9x | **1.21x** | 45.27M | 43.05M | — | — |

CPU columns are min-of-5 `user+sys` from `wait4`, taken while the machine was
idle. The re-timed column reproduces the runner exactly (10 iterations, median,
real `-r` raw files, espice's stdout piped and drained as `runCapture` does) and
was taken while the machine was *busy*, i.e. biased against espice, and espice
still wins. Every deck in that table runs in 5–25 ms, which is 1–5x the process
floor; a median of 10 at that scale is scheduler noise. **Re-time those seven
before treating them as regressions.** The nine above are stable.

Two of the seven are wins on the wall clock partly because ngspice pays a fixed
**10,229,999 Ir of dynamic-linker work** (`do_lookup_x`, `_dl_lookup_symbol_x`,
`_dl_relocate_object`) in *every* run — identical to the instruction in four
separate decks. espice is statically linked and pays ~0.87M. Subtracting both
floors gives a simulation-only Ir ratio, which is the honest number for kernel
work and is worse for espice: `vbic_temp` 1.98, `hfet_inverter` 1.35,
`bjt_npn_output` 1.49. Both statements are true and they mean different things —
espice does more instruction work and still finishes first, because ngspice's
startup is real time.

---

## Rig: how the BJT/VerA decks were made profilable

`docs/perf/remaining-2026-09-10.md` records that valgrind SIGILLs on this
binary's GFNI instruction for decks reaching the BJT/VerA path. That blocked six
of the sixteen (`schmitt`, `fourbitadder` x2, `bjt_npn_output`, `rca3040`,
`hfet_inverter`). It is now unblocked.

The binary has ten `vgf2p8affineqb` sites. Six are the same idiom:

```
vpacksswb / vpermq / vpshufd          ; mask bytes, each 0x00 or 0xFF
vgf2p8affineqb $0x0, <const>, %xmm, %xmm
vpmovmskb %xmm, %r8d
test $0x3fff, %r8d                    ; 9, 10, 13, 13, 14, 22 lanes
```

This is LLVM lowering `@reduce(.Or, corr != 0)` for six different `n_u`. The
constant qword is `0x0000000000000001`, so the affine transform is
`dest.bit[7] := src.bit[0]`, all other bits zero — and `vpmovmskb` reads only
bit 7. On a `vpacksswb` output (0x00/0xFF only, bit 0 == bit 7) the instruction
is a **no-op with respect to its only consumer**.

`/tmp/slowdeck/espice-nogfni` replaces those six with the 10-byte canonical NOP
(`66 2e 0f 1f 84 00 00 00 00 00`), same length, so the instruction count is
unchanged. Verified: **raw output byte-identical to `zig-out/bin/espice` on 19
decks** including all six that SIGILL. The other four GFNI sites (a byte
bit-reverse behind `vmovq`/`bswap`, and a string-compare mask) were left alone.

Two other hazards found here:

- **ngspice diverges under valgrind on `devices/hisim2`.** It reports 30.7e9 Ir
  on one run and 36.9e9 on the next, against 1,717 native iterations and 28.6 ms
  of native user time (~150M instructions). Its Ir on that deck is meaningless.
  Every other deck is stable and reproducible to the instruction.
- **ngspice on `hisim2` is not single-threaded**: elapsed 45 ms against 113 ms of
  CPU, unchanged by `OMP_NUM_THREADS=1`, and 85 ms of that is *system* time. Any
  wall-clock ratio on that deck compares one espice core against several ngspice
  cores. On single-core CPU time the two are at parity (97 ms vs 92 ms); on user
  time alone espice is 3.3x slower. Quote user time or Ir, never wall.
- `timedMedian` uses `runCapture` (pipe + drain) for espice and `runOk`
  (`.ignore`) for every reference. Small, but it is a systematic asymmetry in
  espice's disfavour and belongs in the runner's notes.

---

## Family 1 — the PWL source. One device, 89% of a deck.

`bypass/burst_clock` is not a diode deck and not a digital deck. Deleting the
diode changes its Ir by 5.8%. Deleting the *waveform* changes it by 90%.

Identical topology (`V - 1k - 10n`), `.tran 50n 100u`, ~4,050 Newton iterations
in every row:

| source | espice Ir | extra Ir per Newton iterate |
|---|---:|---:|
| `DC 1` | 11,771,149 | — |
| `PULSE(...)` | 18,219,924 | +200 |
| `SIN(...)` | 12,647,922 | +220 |
| `EXP(...)` | 12,645,177 | +250 |
| `PWL` 2 points | 24,911,788 | **+3,274** |
| `PWL` 4 points | 49,548,140 | **+9,358** |
| `PWL` 10 points | 111,967,847 | **+24,606** |
| `PWL` 20 points | 239,454,848 | **+55,104** |

ngspice on the same ladder: `DC` 44.38M, `PWL` 10 points 45.01M, i.e. **+308 Ir
per timepoint total**.

Per-function confirmation. The vsource batch eval is one function
(`0x2bc9a40`), called once per source per Newton iterate:

| deck | calls | self Ir | Ir/call | share of run |
|---|---:|---:|---:|---:|
| `DC 1` | 4,017 | 257,088 | **64** | 2.2% |
| `PWL` 10 points | 4,069 | 99,493,290 | **24,452** | **88.9%** |
| `devices/hfet_inverter` (PWL 4) | 1,560 | 6,255,986 | 4,010 | **13.8%** |
| `devices/mos6_inverter` (PWL 2) | 1,872 | 1,671,848 | 893 | 1.1% |

A 382x blow-up in one arm of one `if` ladder. Transcendentals are not involved
(1.0 libm call per iterate in the whole `burst_clock` run).

**Mechanism.** `src/devices/models/vsource.va:104-113` declares
`pwl_times[0:63]` / `pwl_values[0:63]`, and its own comment (line 106) states
that FastVAF flattens these into 64 scalar Model fields and turns a *runtime*
index into a 64-deep short-circuiting select chain. The PWL arm
(lines 282-325) does four such indexed reads per table point — `pwl_times[k]`
and `pwl_values[k]` in the last-point walk, and again in the interpolation walk.
The measured cost is ~2,500-2,800 Ir per table point per evaluation, growing
mildly faster than linear, which is the signature of a chain whose slot *k*
costs *k* compares. The 64 `@(timer(...))` declarations on lines 146-209 are
**not** the cost: the DC row above carries all 68 timers and costs 64 Ir.

**Fix.** Two independent halves, either alone is most of the win:

1. Bound the loops so the chain is entered `pwl_len` times and not 64 — or give
   FastVAF a real indexed load for a flattened parameter array. This is a VerA
   codegen change, and it is the general fix: any `.va` with a data table pays
   this today.
2. Failing that, restructure the PWL arm so each point is read once, not four
   times: fuse the last-point walk into the interpolation walk (the file's own
   comment says they were kept separate "because either way it is one select
   chain" — that reasoning assumed the chain was cheap; it is 700 Ir).

Expected: `burst_clock` 120.1M -> ~21M (0.49x -> ~2.5x), `hfet_inverter` -13.8%,
`cpl3_4_line` and `mos6_simpleinv` similar, 10 fixtures touched. **Highest
value/effort ratio in this whole document.**

---

## Family 2 — DC sweeps re-derive every model's parameter block at every point

`devices/{hisim2,vbic_output,hicum2_output,bjt_npn_output,vbic_temp}` and the
`.dc` leg of `ngspice/rca3040` are all 1-D or 2-D `.dc` sweeps over a source,
with one or a few instances.

Iteration counts are not the gap. espice iterates (`ZP_NEWTON_DEBUG=1`, counting
`it=` lines) against ngspice `.options acct` `Total iterations`:

| deck | espice | ngspice | ratio |
|---|---:|---:|---:|
| `vbic_output` | 3,784 | 3,686 | 1.03 |
| `hicum2_output` | 3,626 | 3,638 | 1.00 |
| `bjt_npn_output` | 3,750 | 3,682 | 1.02 |
| `hisim2` | 1,777 | 1,717 | 1.03 |
| `mos6_inverter` | 935 | 879 | 1.06 |

The cost is per iterate, and part of it is not the kernel at all.

Every one of these profiles contains functions called **exactly once per DC
sweep point** (1,810 for the 201x9 decks, 848 for hisim2's 121x7), absent from
every transient profile of the same device, and heavy in `pow`/`log`:

| deck | per-point functions | inclusive Ir | share of run |
|---|---|---:|---:|
| `devices/hisim2` | `0x2878470` + `0x284e9b0` | 101,596,495 | **17.0%** |
| `devices/bjt_npn_output` | `0x22caa70` | 5,887,561 | **11.5%** |
| `devices/vbic_output` | `0x22a9430` + `0x2267530` | 17,524,329 | **12.8%** |
| `devices/hicum2_output` | `0x221cbc0` | 2,660,614 | 2.2% |

Identification is not a guess: `0x22caa70` and `0x2878470` each have *two*
callers — one that calls them once at setup (`0x1f1a070`, the
`ProtoStore.finalize` loop at `engine.zig:1125`, which is literally
`for (0..count) |i| D.precompute(...)`) and one that calls them once per sweep
point. They are `D.precompute`. In `tran/fourbitadder` the same `0x22caa70` is
called 180 times — once per BJT instance, at setup, never again. In
`devices/bjt_npn_output` it is called 1,811 times for a **one**-instance deck.

**Mechanism.** `src/analysis/dc/dc.zig:212` calls `ckt.recompute()` after every
`t.set(v)`. `Circuit.recompute` walks **every batch** and calls
`recomputePrecomputed` -> `reprep` -> `D.precompute(inst, mdl)` per instance
(`engine.zig:1575-1607`), plus `D.collapse` per instance. That is the
temperature/parameter derivation — ngspice's `VBICtemp` / `HSM2temp` / `BJTtemp`
— and ngspice calls it *once*. A `.dc` point moves exactly one `ParamRef`, and
`D.precompute` reads only its own model and instance, so re-deriving the other
batches is pure waste.

For hisim2 that waste is **539 transcendental calls per sweep point**.

**Fix, written (not built):** `Circuit.recomputeType(type_name)` in
`src/analysis/Circuit.zig` and a one-line call-site change at
`src/analysis/dc/dc.zig:212` to pass `t.device_type`. Notes on the shape:

- `Batch.type_name` is `@typeName(D)` (`vsource.Vsource`) while
  `ParamRef.device_type` is only the tail (`Vsource`, `engine.zig:1635-1638`);
  the match is on the tail.
- No match at all falls back to the full walk. A silently skipped
  re-derivation is a wrong answer, not a slow one.
- The temperature outer sweep is unaffected: `setCircuitTemp` -> `setTemp`
  (`engine.zig:1509`) already calls `reprep()` on every batch itself.
- `sweep/lanes.zig:56` keeps its full `recompute()` — MC/temp/sens move many
  parameters at once.

Payoff is the table above, and it lifts far more than these five decks: every
`devices/*_output`, `*_transfer`, `*_sweep` and `dc_sweep/*` fixture pays it.

---

## Family 3 — the compact-model kernel calls 5-10x as many transcendentals

This is the residual after Family 2, and it is the biggest single line.

`devices/vbic_output`, one VBIC instance, per Newton iterate, both engines under
callgrind, call counts from the call graph:

| | espice | ngspice |
|---|---:|---:|
| `exp` | 43.0 | 9.2 |
| `pow` | 36.6 | 7.0 |
| `log` | 41.6 | 1.6 |
| **all transcendental calls** | **176.9** | **17.8** |
| transcendental self Ir | 10,474 (29.0% of run) | 1,132 (7.1%) |
| device kernel self Ir | 15,975 (44.2%) | ~4,953 (top three per-iterate fns) |
| total Ir per iterate | 36,134 | 16,400 (2,550 of it dynamic linking) |

Of espice's 176.9, the kernel itself accounts for 98.8 and the per-point
prologue for 37.3 (Family 2). So even after Family 2 lands, **the VBIC kernel
alone makes 5.5x ngspice's transcendental calls.**

The same measurement across the family, with the kernel isolated (the largest
function, called exactly once per Newton iterate):

| deck | kernel self Ir/iterate | kernel % | trans calls/iterate | ngspice trans/iterate |
|---|---:|---:|---:|---:|
| `devices/hisim2` | 253,131 | 75.1% | 649 total | — (diverges) |
| `devices/vbic_output` | 15,975 | 44.2% | 176.9 | 17.8 |
| `devices/hicum2_output` | 18,960 | 56.6% | 99.4 | 65.3 |
| `devices/bjt_npn_output` | 4,838 | 35.5% | 55.7 | 7.7 |
| `ngspice/schmitt` (4 BJT) | 19,496 | 51.5% | 61.2 | 22.1 |
| `tran/fourbitadder` (252 dev) | 847,932 | 61.7% | 3,000 | 1,194 |
| `ngspice/rca3040` (11 BJT) | 51,291 | 51.1% | 536 | — |

Two facts worth separating:

- **`bjt.va`'s kernel is fine.** Its own transcendental count is 6.11 per
  instance evaluation against ngspice's 7.67. The 55.7 in `bjt_npn_output` is
  Family 2, not the model. What makes `fourbitadder`/`schmitt`/`rca3040` slow is
  the kernel's *inline* cost (61.7%/51.5%/51.1% self), not its libm calls.
- **`vbic13_4t.va` and `hisim2_va.va` are different.** Their kernels call 5.5x
  and (for hisim2) an unmeasurable multiple of ngspice's libm count. That is a
  model-source problem of exactly the shape
  `docs/device-eval-vs-ngspice-2026-09.md` Finding 2 found in `mos1.va`:
  ngspice's `vbicload.c` / `hsm2load.c` guard whole blocks (`if (Cbe != 0)`,
  zero-area junctions, unset parasitics) that the `.va` evaluates
  unconditionally, and it precomputes in `*temp` what the `.va` recomputes.
  Nobody has done the block-by-block diff for these two the way it was done for
  mos1/mos6. That diff is the work.

The second-largest function in every one of these profiles is `0x1fa9800`,
called exactly once per Newton iterate, **9.2-11.4% of the run** in every deck
(4,121 Ir/iterate on one VBIC; 126,336 on fourbitadder's 252 instances, i.e.
501 per instance). That is the second device walk — `applyLimits`/`limitRange`
— which `docs/device-eval-vs-ngspice-2026-09.md` priced at 8.4% on mos1. It
reproduces here at 9-11% on every compact model. It is the same known item, now
confirmed to be family-wide rather than mos1-specific.

---

## Family 4 — digital / edge-heavy transients: **step COST, not step count**

This is the question the next phase hangs on, so here is the whole table.
espice from `ZP_TRAN_STATS=1`, ngspice from `.options acct`:

| deck | ng accepted | zp accepted | ng tran iters | zp NR iters | zp rejects |
|---|---:|---:|---:|---:|---|
| `bypass/burst_clock` | 2,041 | 2,040 | 4,082 | 4,082 | lte=1 |
| `ngspice/schmitt` | 2,018 | 2,016 | 4,057 | 4,225 | none |
| `tran/fourbitadder` | 59 | 58 | 124 | 156 | none |
| `ngspice/rca3040` | 108 | 113 | 320 | 350 | lte=2 |
| `devices/hfet_inverter` | 323 | 324 | 1,037 | **769** | newton=4 lte=2 |
| `devices/mos6_inverter` | 315 | 316 | 852 | 884 | newton=2 lte=2 |
| `devices/lossy_tline` | 632 | 630 | 1,262 | 1,260 | none |
| `tline/txl1_1_line` | 493 | 495 | 1,170 | 1,133 | none |
| `ensemble/pvt_corners` | 2,064 | 2,161 | 4,336 | 4,870 | newton=12 lte=40 |

**Timestep counts agree within 2% on eight of nine decks** (`pvt_corners` +4.7%
is the worst, and that deck is a win anyway). Newton iterations agree within 5%
on six of nine; the outliers are `fourbitadder` +26%, `rca3040` +9% and
`hfet_inverter` **-26%** (espice takes fewer). Rejected steps are 0-2 almost
everywhere.

**Timestep control, LTE and breakpoint handling are not the problem, and no work
on them will move these decks.** The gap is entirely in the cost of one Newton
iteration, and Families 1 and 3 say what that cost is: for `burst_clock` the PWL
source (89%), for `schmitt`/`fourbitadder`/`rca3040` the BJT kernel's inline
arithmetic (51-62% self) plus the limiting walk (8-11%).

Worked example, `tran/fourbitadder` (451 equations, 180 BJT + 72 diodes):

| | espice | ngspice |
|---|---:|---:|
| Ir, floor-corrected | 290.5M | 126.6M |
| iterations | 156 | 179 |
| Ir per iteration | 1,862,000 | 707,000 |
| device kernel self | 61.7% | — |
| limiting walk (`0x1fa9800`) | 9.2% | inline in `BJTload` |
| transcendental calls per iteration | 3,000 | 1,194 |

espice does *fewer* Newton iterations and 2.6x the work per iteration.

---

## Family 5 — transmission lines: no loss to explain

`devices/lossy_tline` and `tline/txl1_1_line` are wins on every metric
(Ir 0.71 and 0.44; CPU 10 ms vs 17 ms and 5 ms vs 10 ms; re-timed wall 1.54x and
2.36x). Step counts match ngspice to within 2 of 632 and 2 of 493.

The hypotheses in `docs/perf/arpice-devices.md` — LTRA coefficient sharing
across identical history grids, TXL exponential reuse for duplicated poles,
splitting the 320 KiB history arrays out of the Instance — remain **unmeasured**,
and they stay that way here: there is no deficit on these fixtures to motivate
them. The memory item is still real on its own terms (320 KiB per LTRA instance,
80 KiB per TXL) and should be judged against the memory goal, not this one.

## Family 6 — sweeps: the lane machinery is not involved, and there is no loss

- `sweep/amp_bias_sweep` is a plain `.dc Vgs 0 3.3 0.01` over one MOS1. `.dc`
  goes through `dc.zig`'s warm-started serial march, not `sweep/lanes.zig`
  (which serves mc/temp/sens/dcmatch). It should not engage: warm-starting from
  the previous point is the whole reason a `.dc` sweep is cheap, and a lane
  solve is cold-start-only (`dc.zig:135-140` says so). Total run is 4.95M Ir
  against ngspice's 19.99M.
- `ensemble/pvt_corners`, despite the name, has no corner directive at all — it
  is a 6-MOSFET inverter chain under one `.tran`. 72.79M Ir against 91.46M.

Neither deck pays "full setup per point" in any measurable sense. Both rows in
RESULTS.md are noise. The one real finding in this area is Family 2, which is a
`.dc` problem and does touch `amp_bias_sweep` (331 points x 1 instance), just
not enough to matter at 4.95M total.

---

## Ranked fixes

| # | fix | decks lifted | measured payoff | effort |
|---|---|---|---|---|
| 1 | **PWL: stop expanding `pwl_times[k]`/`pwl_values[k]` into a 64-way select chain** (VerA codegen, or fuse the two walks in `vsource.va`) | `burst_clock`, `hfet_inverter`, `cpl3_4_line`, `mos6_simpleinv`, `mos6_inverter`, +5 | 88.9% of a PWL-10 run, 13.8% of `hfet_inverter`; `burst_clock` 0.49x -> ~2.5x | VerA change, or a local `.va` rewrite |
| 2 | **`recomputeType` — per-DC-point recompute only for the swept batch** (written, `Circuit.zig` + `dc.zig:212`) | every `.dc` fixture; `hisim2`, `vbic_output`, `bjt_npn_output`, `hicum2_output`, `vbic_temp`, `rca3040` | 17.0% / 12.8% / 11.5% / 2.2% | ~20 lines, written, unbuilt |
| 3 | **Block-by-block diff of `vbic13_4t.va` and `hisim2_va.va` against `vbicload.c`/`hsm2load.c`**, the way mos1/mos6 were done | `vbic_output`, `vbic_temp`, `hisim2`, `hicum2_output` | VBIC kernel makes 98.8 transcendental calls/eval against ngspice's 17.8; hisim2 kernel is 253,131 Ir/eval and 75.1% of its run | days; highest ceiling |
| 4 | **The limiting walk** — `0x1fa9800`, one call per Newton iterate, 9.2-11.4% of *every* compact-model deck measured | all nine | 9-11%, family-wide (previously known only for mos1 at 8.4%) | see `remaining-2026-09-10.md` item 2 |
| 5 | **`bjt.va` inline arithmetic** — 51-62% self on `fourbitadder`/`schmitt`/`rca3040` with a *correct* libm count (6.11 vs 7.67) | `fourbitadder` x2, `schmitt`, `rca3040` | unquantified; the libm lever does not apply here, so this is an expression-level diff against `bjtload.c` | days |
| 6 | **Re-time the seven noise rows and fix the runner** — pin down short-deck timing (more iterations, or minimum instead of median, or CPU time), symmetrize `runCapture`/`runOk`, and record ngspice's 10.2M dynamic-linker floor in RESULTS.md | 7 rows | removes 7 false regressions | small |

Fixes 1 and 2 together are the whole of `burst_clock` and roughly a sixth of the
four DC-sweep decks, for a day of work between them. Fix 3 is where the
remaining 2-3x on `hisim2`/`vbic_output` actually lives.

## Not re-opened

Nothing in `remaining-2026-09-10.md`'s "Settled" table was re-proposed:
instance-axis SIMD, derivative narrowing, out-params, dead-path outlining,
packing structurally-zero rows, `@call(.always_inline, D.limit)`. The dedup /
eval-cache item (its #3) is worth re-reading in light of Family 2: on a `.dc`
sweep with one instance there is nothing to dedup, so it changes none of these
decks.
