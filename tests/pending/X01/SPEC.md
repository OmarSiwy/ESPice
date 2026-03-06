# X01 — LTRA, TXL and coupled transmission lines

Pending host fixtures. Thirteen decks with checked-in expected JSON in the same
schema as `tests/fixtures/`, none of them wired into the discovered suite yet.

## Ground truth established before writing anything

The native models are **implemented and registered**, not stubs. Verified in the
tree, not from the plan text:

- `models/native/ltra_native.zig`, `txl_native.zig`, `coupled_ltra.zig` exist.
- `src/frontend/models.zig:196-197` exports `ltra_native` and `txl_native` via
  `byName`; `coupled_tlines` is a `DeviceId.Type`.
- `src/frontend/builder.zig:1157-1170` routes an O card with `rc or r_t > 0` to
  `devices.ltra_native`, and falls through to the ideal Bergeron `tline` for the
  lossless LC case. Y and P cards route to `txl_native` and the CPL dimensions.
- `zig-out/bin/espice` runs all thirteen decks below and **all thirteen exit 0**.
  (An earlier draft of this line said "twelve complete, one errors". That was
  wrong: none of the thirteen errors. The three then-failing fixtures failed on
  *values*, not on status, and the `TimestepTooSmall` abort that the sentence was
  presumably remembering belongs to a `reltol=1e-9` variant that is **not** any
  checked-in deck — see *Deliberately NOT covered*.)

So this is an "implemented without evidence" row for everything except AC. The
fixtures pin the behaviour regardless. Measured against an `espice` **built from
source at HEAD** (`zig build install`, ARPice's Q03 build fix having landed),
**9 of 13 pass and 4 fail**, and each of the four failures is a distinct real
defect (listed under *Current status* below).

## LRM clauses covered

X01 is an **ngspice-compatibility** row, and the audit deliberately keeps that
separate from AMS conformance. Read against the offline LRM the separation is
sharper than the plan suggests:

- **Annex E.3, Table E.1** (`docs/annex-e-spice.html`, `#sE-3`) — the only
  transmission line the standard names is `tline` with ports `t1, b1, t2, b2`
  and parameters `z0, td, f, nl`. **LTRA, TXL and CPL appear nowhere in the LRM.**
  E.1.1 says "Verilog-AMS HDL makes no judgment as to which of the various SPICE
  languages should be supported", and E.3 notes "The mathematical description of
  the built-in primitives can differ... Verilog-AMS HDL offers no solution in
  this case other than the possibility that if the model equations are known, the
  primitive can be rewritten as a module."
  Consequence for this row: **no fixture here may be cited as LRM conformance
  evidence.** Every expected value below is derived from the telegrapher
  equations and from ngspice-44.2 behaviour, not from a clause.
- Clauses that bound a future pure-source rewrite, confirmed present in the
  offline HTML: **4.3** Built-in mathematical functions (4.3.1 standard, 4.3.2
  transcendental — note `erfc` and Bessel-I are *not* listed, which is why LTRA's
  RC kernels cannot be translated directly); **4.5.7** Absolute delay operator;
  **4.5.11** Laplace transform filters (4.5.11.1–4.5.11.5); **4.5.14** Constant
  versus dynamic arguments; **4.5.15** Restrictions on analog operators;
  **9.17.2** `$bound_step` Task. These are the standard facilities a replacement
  would have to be built from; none of them prescribes ngspice's convolution,
  Padé fit, integer-picosecond history stamping, or accepted-step sequence.

## Oracle policy

Every expected value is a **closed-form hand derivation** stated in the `.sp`
header, then independently confirmed by an ngspice-44.2 run of the exact same
netlist. Both numbers are reported. The two AC fixtures use the exact
telegrapher solution

    gamma = sqrt((r+jwl)(g+jwc)),  Zc = sqrt((r+jwl)/(g+jwc)),  gL = gamma*len
    Zin   = Zc (RL + Zc tanh gL)/(Zc + RL tanh gL)
    v(a)  = Vs Zin/(Rs+Zin),   v(b) = v(a)/(cosh gL + (Zc/RL) sinh gL)

which reproduces ngspice-44.2 to <= 1.3e-15 over all 32 points (9.2e-16 on the
lossy deck, 1.24e-15 on the lossless-limit deck) — a genuine dual oracle, so a
disagreement cannot be blamed on either side alone.

The step-driven transient fixtures use Bergeron reflection algebra
(`Gamma = (RL-Z0)/(RL+Z0)`) sampled in the middle of plateaus. The two
sine-driven ones (`ltra_tran_long_run_past_8192`,
`ltra_tran_rejected_step_retry`) cannot do that and do not claim to: on a curved
waveform the runner's `sample()` (`tests/test_correctness.zig:510`) interpolates
linearly between accepted points, with error bounded by `(h^2/8)*|v''|`. That
bound is stated in each of those two `.sp` headers with the arithmetic, and the
`atol` is set above it — 5e-6 against a 1.54e-7 bound for the 1 ps deck, 5e-5
against a 3.9e-6 bound for the 20 ps deck. The digits are written because the
closed form gives them; the *tolerance* is the thing that is not tightened to
the ULP, because the accepted-point grid is the implementation's to choose and
the LRM/ngspice do not fix it. Both bands are still four to six orders below the
defect they gate.

No reject fixtures. The runner's `checkRejection` category map
(`tests/test_correctness.zig:214-229`) has no category for
`UnsupportedTransmissionLineParameters`, so a rejection fixture could not be
expressed without editing the runner, which is out of scope for this row.

## One line per fixture

| Fixture | Pins | Expected value and derivation |
|---|---|---|
| `ltra_op_series_resistance` | LTRA DC is `r*len` and **nothing else** | Two lines with the same `r*len` but different `Z0` and `Td`: `lline` r=0.5 len=2 (`Z0=50`, `Td=10 ns`) and `lline2` r=0.125 len=8 (`Z0=100`, `Td=320 ns`). Both give `R_line=1`, loop `50+1+50=101` -> `v(a)=51/101=0.504950495049505`, `v(b)=50/101=0.49504950495049505`, `i(vin)=-1/101`, on **both** lines. A `Z0` stamp gives `100/150` vs `150/200` (the two lines disagree); a short gives `0.5` on both, 4.95e-3 off. ngspice delta 0.0 |
| `ltra_ac_lossless_limit` | LTRA AC phasor rotates, into `RL=3*Z0` | `Z0=50`, `Td=10 ns`, `GammaL=+0.5`: `v(a)=0.5(1+0.5 exp(-2j theta))`, `v(b)=0.75 exp(-j theta)`, `theta=(2k-1)pi/8`, k=1..8 (6.25..93.75 MHz). Odd eighths deliberately avoid the multiples of `pi/2` where `v(a)` turns real. Tabulated values are the exact telegrapher solution keeping `r=1e-6` (`alpha L = 2e-8 Np`), which agrees with the ideal form to 1.7e-8. All 24 values are complex; closest approach to the host's DC answer is 0.19134171. ngspice delta <= 1.3e-15 |
| `ltra_ac_lossy_telegrapher` | LTRA AC with `R_total = 10 ohm` | Exact telegrapher formula above at 8 points; e.g. 12.5 MHz `v(a)=0.529637028-0.028179052j`, `v(b)=0.320461585-0.321816898j` (so `|v(b)|=0.45416048`). DC limit would be `0.5454545+0j`/`0.4545455+0j`. ngspice delta <= 9.2e-16 |
| `ltra_tran_mismatched_load` | Bergeron staircase, `GammaL=+0.5` | `Vi=0.5`; `v(a)=0.5` for `t<2Td` then `0.75`; `v(b)=Vi(1+GammaL)=0.75` for `t>Td`. DC check `150/200=0.75`. ngspice delta <= 1.3e-8 |
| `ltra_tran_shorted_far_end` | reflection sign at a near-short | `GammaL=(0.05-50)/(0.05+50)=-0.998001998001998`; both plateaus settle at `Vi(1+GammaL)=0.000999000999001`, matching DC `0.05/50.05`. ngspice delta <= 4.0e-8 |
| `ltra_tran_long_run_past_8192` | live history deeper than LTRA CAP=8192 | Sine drive `SIN(0 1 250meg)`, matched both ends, forced `dt=1 ps`: the far-end value needs an entry 10000 accepted points back (1808 past the bound), and no triple of a sine is collinear, so compaction cannot hide the overflow. `Td=10 ns` is 2.5 periods, so `v(b)=-v(a)` after the wavefront and a lost entry gets the **sign** wrong. ngspice delta <= 1.4e-7 |
| `ltra_tran_rejected_step_retry` | accepted history survives rejected trials | Sine drive `SIN(0 1 62.5meg)` into the same `RL=150` line plus a 1 pF far end, `reltol=1e-8` with no user `tmax`: 2966 accepted points against 2258 with `.options` deleted, same values to 5.4e-6, both under 8192. Phasor closed form with `ZL=1/(1/RL+jwCL)`; the `t=15 ns` row (`Td<t<2Td`) pins `v(a)` at the pure incident `-0.191342` while `v(b)` is already `+0.696985`. Adds a `repeatability` check. ngspice delta <= 5.3e-6 |
| `txl_tran_matched_step` | TXL Padé fit is a transparent 10 ns delay | `Rs=RL=Z0=50` -> `v(a)=0.5`, `v(b)=v(a)(t-10 ns)`. The 9.9 ns sample pins `Td` from below. ngspice delta <= 5.0e-12 |
| `txl_tran_mismatched_load` | TXL twin of the LTRA mismatch | Identical electrical line and identical expected numbers (`0.5`/`0.75`) through a different native kernel, so the two fixtures cross-check each other. ngspice delta <= 1.1e-11 |
| `txl_tran_long_run_past_2048` | live history deeper than TXL CAP=2048 | `Td=5 ns` at forced `dt=1 ps` needs an entry 5000 points back. Step at 6 ns -> far-end edge at 11 ns; `v(b)=0` at 10.9 ns. ngspice delta <= 3.8e-12 |
| `cpl_op_dc_decoupled` | CPL DC is `R*length` per conductor, conductors independent | Two P cards with the same `R*length=6` but halved modal impedances and 32x the delay (`cmod`: `Ze/Zo=100/25`, `Td=12 ns`; `cmod2`: `50/12.5`, `Td=384 ns`). Conductor 1 loop `10+6+40=56` -> `v(a1)=46/56`, `v(b1)=40/56`, `i(v1)=-1/56` on both cards; conductor 2 exactly 0 on both despite `L12=150n`, `C12=-60p`. ngspice delta <= 2.9e-12 |
| `cpl_tran_even_mode` | even-mode impedance `Ze=100`, `Td=8 ns` | `Le=L11+L12=400n`, `Ce=C11+C12=40p` -> `Ze=sqrt(10000)=100`; `Le Ce = Lo Co = 1.6e-17` so the medium is homogeneous and `Td=2 m * 4 ns/m`. Common-mode drive/termination at 100 ohm gives a flat `0.5` delayed by 8 ns. ngspice delta <= 1.5e-9 |
| `cpl_tran_odd_mode` | odd-mode impedance `Zo=25`, `Td=8 ns` | `Lo=L11-L12=100n`, `Co=C11-C12=160p` -> `Zo=sqrt(625)=25`. Differential drive/termination at 25 ohm gives `+0.5`/`-0.5` delayed by 8 ns. With the even-mode fixture this pins both eigenvalues of the 2x2 L and C matrices. ngspice delta <= 1.5e-9 |

## Current status against `zig-out/bin/espice` built from source at HEAD

Nine pass, all thirteen exit 0. The four failures are the deliverable:

1. **`ltra_ac_lossless_limit` — 24 of 24 values wrong** (was 7 of 24 before the
   load was moved off `Z0`; see *Corrected after review*). The host returns
   `v(a)=0.7500000025+0j` and `v(b)=0.7499999925+0j` at every frequency, purely
   real. That is `(150+2e-6)/200.000002` and `150/200.000002`, i.e. the DC
   divider through `R = r*len = 2e-6`, not an AC stamp.
2. **`ltra_ac_lossy_telegrapher` — 24 of 24 values wrong.** The host returns
   `v(a)=0.545454545+0j` and `v(b)=0.454545455+0j` at every frequency, which is
   exactly `60/110` and `50/110`, the DC solution. This reproduces and quantifies
   the "AC probe" paragraph of `docs/native-transmission-line-migration.md`
   against a dual oracle, for both the lossless-limit and the genuinely lossy line.
3. **`txl_tran_long_run_past_2048` — `v(b)` at 10.9 ns is `0.5`, expected `0`.**
   The far end publishes the wavefront at 8.0585 ns instead of 11.0055 ns. The
   error is `6 ns + 2048 * 1 ps = 8.048 ns`, i.e. exactly the front-pruning
   horizon. Isolated: the identical circuit at `tmax=10 ps` (1301 accepted
   points, under the bound) puts the edge at 11.012 ns on both the host and
   ngspice. This upgrades the documented "CAP=2048 front pruning *can* discard a
   still-live point" from a note to a reproducible corruption.
4. **`ltra_tran_long_run_past_8192` — 6 of 14 values wrong, the sign wrong on
   every one of them.** New failure; the previous, step-driven version of this
   deck passed and would have kept passing with `CAP=8`. With the sine drive the
   host returns `v(b) = +0.297982` at 13 ns where `-0.5` is required, and
   `-0.419315` at 23 ns where `+0.5` is required — a 0.919 V error on a 0.5 V
   amplitude. The LTRA 8192 bound is therefore a **live** corruption, exactly
   like the TXL 2048 one, and not the theoretical risk the old text claimed.
   Isolated the same way: the identical deck at `tmax = 10 ps` (2507 accepted
   points, under the bound) matches the closed form to 1.22e-5, inside its own
   1.54e-5 interpolation bound.

## Deliberately NOT covered

- **TXL and CPL AC.** ngspice-44.2 has no AC stamp for the Y card: the same
  matched line returns `v(a)=0.49999999999875+0j`, `v(b)=-1.25e-12+0j` at all
  eight frequencies, frequency-independent. There is therefore no compatibility
  oracle, and pinning the analytic value would encode a permanent disagreement
  with the reference simulator. Needs a decision before a fixture exists.
- **CPL dimensions 3 and 4**, and rejection beyond the native supported set.
- **Non-ground CPL/TXL reference nodes.** Every deck here grounds both reference
  nodes, so the documented divergence (native TXL/CPL ignore card reference
  nodes, the approximate `.va` model honours them) is not exercised.
- **RC and RG line classes, and the LC/ideal branch.** All LTRA decks here are
  RLC. `r=1e-6` keeps the RLC route selected while staying within `2e-8 Np` of
  the lossless answer; it does not touch the `rc` branch or `erfc` dispersion.
- **`reltol=1e-9` with a sharp edge.** Re-measured after the retry deck was
  rewritten, because the old claim was tied to the old deck. The checked-in
  sine-driven retry deck at `reltol=1e-9` now **completes** (3773 accepted
  points; ngspice 3112). What aborts with `TimestepTooSmall` is the *previous*,
  `PULSE(0 1 0 10p 10p 500n 1u)` form of the same circuit at `reltol=1e-9` —
  reproduced today, exit path `Error: <deck>: TimestepTooSmall`. So the open item
  is narrower than it was written: a 10 ps source edge plus a 1 pF far-end load
  plus `reltol=1e-9` defeats the step controller. That is a convergence report,
  not a history report, and it does not belong in this row; it is left here as a
  pointer and is not pinned by any checked-in deck.
- **UIC, analysis restart, `nosteplimit`, steps longer than the delay, breakpoint
  ring overflow, multiple independent instances, parameter re-preparation** — all
  named in the migration doc's gate list, none covered here.
- **Bitwise or residual-level comparison** against the native Zig kernels. These
  are end-to-end waveform comparisons with stated tolerances, which is gate 1 of
  the migration doc's list only at the simulator level, not the prescribed-grid
  level.

## Build and run

These are not discovered yet: `tests/fixture_catalog.zig` walks `tests/fixtures`
only, so nothing here affects the current suite. To wire them up, move the
thirteen `.sp`/`.expected.json` pairs into `tests/fixtures/tran/`,
`tests/fixtures/ac/` and `tests/fixtures/op/` by their `analysis` field, then:

```sh
cd /home/omare/Documents/Projects/Zig/ARPice
zig build test -- --filter tran/ltra_ --filter tran/txl_ --filter tran/cpl_
zig build test -- --filter ac/ltra_ac_
zig build test -- --filter op/ltra_op_ --filter op/cpl_op_
ESPICE_SOLVER=jfnk zig build test -- --filter tran/ltra_tran_
```

`netlist_sha256` in each JSON is the SHA-256 of the `.sp` exactly as checked in;
editing a deck without regenerating its oracle makes the runner report
`StaleOracle`. To re-derive every expected value from scratch and re-confirm it
against ngspice-44.2, the closed-form derivations are fully stated in each `.sp`
header — no generator script is required and none is checked in.

## Reproduction — exactly what was run, and what was not

Stated plainly because the row previously overstated it.

Everything numeric in this document was produced today, on an `espice` **built
from source** (`cd ARPice && zig build install`; ARPice's Q03 build fix has
landed, so the "measured against a stale checkpoint binary" caveat no longer
applies), and on `ngspice-44.2` from `$PATH`. Per deck:

```sh
espice -b --format=csv -r out.csv tests/pending/X01/<deck>.sp     # host
ngspice -n -b <deck-with-a-.control-block>.sp                     # oracle
```

`ngspice` will not run these decks verbatim — they carry no `.print`/`.plot`, so
ngspice says "no simulations run". The oracle runs used a copy of each deck with
a `.control`/`.endc` block (`wrdata` or `write` with `set filetype=ascii`) and
were compared back against the checked-in `.sp` by hand; `espice` conversely
rejects a `.control` block with `ParseError`. That asymmetry is why the checked-in
decks are in the `espice` dialect and the ngspice confirmation is a derived copy.

**What was NOT run: the real runner.** `tests/fixture_catalog.zig:6` walks
`tests/fixtures` only, and moving these decks there is outside this row's scope.
The pass/fail counts above come from re-implementing the comparison in
`tests/test_correctness.zig` — `close()` (`:347`, `hypot(a-e) <= atol + rtol*|e|`),
`sample()`'s linear interpolation (`:510`), the `exact` row-by-row path and the
`netlist_sha256` staleness check (`:156`) — over the CSV that `espice` writes.
`checks: [{kind: repeatability}]` on the retry deck is **not** emulated. Treat
"9 of 13 pass" as verified against the oracle semantics, not against the runner
binary; the first thing to do after `git mv`-ing these into `tests/fixtures/` is
to confirm the count is still 9.

## Corrected after review

The audit found four defects in this row. All four are fixed here; two of them
required changing what a deck actually asserts, not just its prose.

1. **`ltra_tran_long_run_past_8192` gated nothing** (audit class A — the worst
   kind, because the cheap way to make it pass is to break the implementation).
   Its header claimed `compactrel = compactabs = 1e-30` disabled straight-line
   compaction. That is false, and the header now says so with the arithmetic:
   `ltra_native.straightLineCheck` (`:277`) computes
   `quad1=(|y2|+|y1|)/2*|x2-x1|`, `quad2=(|y3|+|y2|)/2*|x3-x2|`,
   `quad3=(|y3|+|y1|)/2*|x3-x1|` and accepts when
   `(quad1+quad2)*reltol + abstol > |quad3-quad1-quad2|`. On a flat, evenly
   spaced plateau `quad3 = quad1 + quad2` identically, so the right-hand side is
   zero and the test accepts for *any* positive tolerance. A step-driven matched
   deck is nothing but plateaus, so the history compacted on every overflow and
   the deck would have passed with `CAP = 8`. **Tolerances cannot disable
   compaction; only curvature can.** The deck is now driven by
   `SIN(0 1 250meg)`. It fails 6 of 14 values with the wrong sign, and the
   underlying defect — a live LTRA history overflow — is now visible rather than
   banked. The expected values are the closed form `0.5 sin(wt)` /
   `0.5 sin(w(t-Td))`, re-derived, not transcribed.
2. **Two wrong numbers in `.sp` prose** (audit class C), both re-derived rather
   than copied from the review:
   - `ltra_ac_lossless_limit.sp` stated the DC-stamp fallback as
     `0.495049504950495+j0`. That is `ltra_op_series_resistance`'s number
     (`r=0.5`, `R_line=1`). This deck has `r=1e-6`, so `R_line=2e-6` and the
     fallback is `(RL+2e-6)/(200.000002)`. Confirmed by running the host: it
     returns `0.7500000025` / `0.7499999925` at all eight frequencies with the
     new `RL=150`. The self-inconsistent "fails rows 1..7" is gone with the
     rewrite in item 3.
   - `ltra_ac_lossy_telegrapher.sp` stated `|v(b)| = 0.4543` at 12.5 MHz.
     Re-derived from its own tabulated row:
     `|0.32046158459058616 - 0.3218168980723724j| = 0.4541604816397318`. The
     review's `0.45416048` is right; the tabulated complex values were always
     correct and are unchanged. Header and SPEC now both read `0.45416048`.
   - Two further numbers were wrong in the *first* attempt at this correction and
     are fixed here too: the lossless header's "none is within 0.28 of the DC
     answer" (the binding margin is `v(a)`'s **0.19134171**, not `v(b)`'s 0.29),
     and its "the two agree to 1.5e-8" (measured max **1.67e-8**).
3. **Half the row was satisfied without the feature** (audit class D). Three
   separate fixes:
   - `ltra_ac_lossless_limit` terminated in `RL = Z0`, which makes `Zin = Zc` at
     every frequency and `v(a) = 0.5 + 0j` everywhere — the same number the DC
     fallback returns. 17 of its 24 values were therefore free. `RL` is now
     `150 = 3*Z0` and the eight frequencies moved to the odd eighths
     `theta = (2k-1)pi/8`, off the multiples of `pi/2` where `v(a)` turns real.
     **24 of 24 values now discriminate**, measured.
   - Both `.op` decks asserted exactly the DC-resistance answer the broken path
     produces, and `ltra_op`'s three numbers were algebraically one number. Each
     deck now carries a **second, electrically different line with the same
     `r*len` (resp. `R*length`) and different `Z0`/`Td`**, and asserts that the
     two give a bit-identical answer. That is the identity the DC limit of the
     telegrapher equations actually states — `L` and `C` carry no DC current, so
     `Z0` and `Td` must cancel — and it is not satisfiable by any stamp that is a
     function of `Z0` or of the delay. Both decks still pass, and are now
     honestly labelled regression gates rather than coverage.
   - `ltra_tran_rejected_step_retry` asserted values numerically identical to
     `ltra_tran_mismatched_load`. The reason is structural, not cosmetic: on a
     plateau every history entry holds the same number, so writing a rejected
     trial value into the accepted history changes nothing observable, and the
     fixture could not fail for its own stated reason. It is now sine-driven with
     the closed form taken in the phasor domain (the 1 pF far end makes
     `GammaL` complex), and its `t = 15 ns` row — `Td < t < 2Td`, `v(a)` still
     pure incident while `v(b)` is already reflected — is a value the old deck
     had no way to express.
4. **"Twelve complete, one errors"** (audit class 5.6, reproduction). All
   thirteen exit 0; the line is corrected at the top of this document, and the
   new *Reproduction* section states exactly which binary produced the numbers
   and — more importantly — that the real runner was **not** used and why.

**Not changed, and why.** The audit's class-B sweep records X01's citations as
clean and this row claims no LRM conformance at all (see *LRM clauses covered*),
so nothing was withdrawn and no claim moved to another row. No reject fixture was
added: the runner's `checkRejection` category map
(`tests/test_correctness.zig:214-229`) still has no category these decks could
name, and inventing one would mean editing the runner.

**Where a disagreement with the review is recorded.** The review grouped both
`.op` decks as "assert exactly the DC-resistance answer the broken path
produces". For `cpl_op_dc_decoupled` that was only half right even before the
rewrite: its conductor-2-is-exactly-zero assertion is a genuine discriminator
(a model that leaks DC through `L12 = 150n` / `C12 = -60p`, or that applies the
off-diagonal `R` entry, moves it off zero while conductor 1 carries 17.86 mA),
and `R11*length = 6` is not the `0` a short-circuit stamp gives. The deck was
strengthened anyway rather than argued, because disclosure is not a fix — but the
record should show that the original CPL deck was not vacuous.
