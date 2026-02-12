# Fail audit — the 7 FAILs at 446268a

Baseline: `docs/perf/baseline-446268a.md`, 154 PASS / 7 FAIL / 64 N/A / 23 SKIP
against ngspice 44.2. Gate: per-variable RMS ≤ 1e-3 **and** max ≤ 1e-2,
normalized by `max(peak, span, 1)`.

Reference C source used throughout: ngspice-44.2, extracted from the nix store
tarball to `/tmp/ng/ngspice-44.2` (`nix-store --realise
/nix/store/pfaksd0kl46y99lq6s4axsc89f8vbngj-ngspice-44.2.tar.gz.drv`).

## Method, and two corrections to the brief

Every fixture was re-run in both engines, both raw files parsed, and diffed
per-variable/per-timepoint with a replica of `benchmark/src/runner.zig`
`comparePlots` — **including its edge-phase re-sample window**
(`benchmark/src/runner.zig:515-537`). That matters: the comparator already
re-samples the candidate at 9 points across ±`max(dt_lo, dt_hi, dt_cand)` and
keeps the best match, so any residual has *already survived* a one-grid-step
realignment. "Edge phase" therefore cannot be asserted; it has to be shown to
be phase larger than one reference step, or curvature the 9-point scan steps
over.

The discriminator used for every transient fixture is a **grid-convergence
run**: the same deck with an explicit `tmax` tightened 10-1000x, in both
engines. Then each engine's default run is scored against that converged
reference. That answers "who is wrong" instead of "who differs".

Two premises in the brief are wrong and the audit turns on both:

1. **`devices/bsim4` `max == rms` is not "a uniform offset across every
   sample".** The deck is `.op` — **one** sample. `max == rms` is arithmetic,
   not evidence. (It is still a real model defect; see below.)
2. **`ensemble/pvt_corners` is not a corner sweep.** The deck
   (`benchmark/fixtures/ensemble/pvt_corners/circuit.sp`) is 14 lines with a
   single `.tran 10n 20u`. No `.step`, no `.temp`, no `.mc`, no lanes. The
   "PVT corner lanes" in the comment is aspirational. There is no corner to
   localize; the question "which corner / temperature or process" has no
   referent. What the deck does have is a `PULSE` with period 10 u inside a
   20 u run, so every error appears twice, identically (sample 110 ≡ sample
   1138 to 8 digits) — one rise event and one fall event, full stop.

---

## Ranking (most-defect first)

| # | fixture | verdict | who is closer to the converged answer |
|---|---|---|---|
| 1 | `devices/bsim4` | **real model defect — found, fixed** | n/a (DC) |
| 2 | `ngspice/mosamp` | **real espice defect** (LTE state granularity) | ngspice, 1.3x |
| 3 | `devices/mos6_inverter` | same mechanism, milder | ngspice, 1.8x |
| 4 | `scaling/parallel_inverters_2000` | not a defect — tie | tie |
| 5 | `vacask/mul` | not a defect — startup grid phase | n/a (both tmax-locked) |
| 6 | `devices/hfet_inverter` | not a defect — **ngspice is worse** | espice, 13.7x on edge phase |
| 7 | `ensemble/pvt_corners` | not a defect — **ngspice is wrong** | espice, 3.5x; ngspice overshoots its own rail |

---

## 1. `devices/bsim4` — 1.69e-3 / 1.69e-3 → **3.14e-6 / 3.14e-6** (fixed)

### Symptom and worst sample

One `.op` point, five variables. Only `v(d)` and `i(vdd)` carry error, and
they are the same fact:

```
v(d)     ng 0.11080614       zp 0.112496649      e = 1.691e-3
i(vdd)   ng -9.8919386e-05   zp -9.87503351e-05  e = 1.691e-7 (denom 1.0)
```

`Rd = 10k`, `Vdd = 1.1`, so `v(d) = 1.1 - 10k·Id`. The whole error is
`Id`: 98.919 µA vs 98.750 µA, **-0.171 %**.

### Edge or systematic

Systematic, and not marginally so. A 2-D `Id(Vgs, Vds)` probe of the same
default-parameter device (`.dc Vd 0 1.2 0.02 Vg 0.2 1.2 0.25`) shows espice
low **everywhere**, bias-dependently:

| Vgs | rel. error at Vds=0.1 | at Vds=1.2 |
|---|---|---|
| 0.20 | -4.79 % | -4.63 % |
| 0.45 | -2.69 % | -2.06 % |
| 0.70 | -1.14 % | -0.94 % |
| 1.20 | -0.84 % | -0.64 % |

A fine `Vgs` sweep at `Vds=0.05` shows the deficit saturating at exactly
**-4.89 %** through deep subthreshold, with the subthreshold slope
`n·Vt = 0.029021` **identical to 5 digits** in both engines. Identical slope
plus a constant multiplier = a pure `Vth` offset in weak inversion
(δ = +1.45 mV), but strong inversion needs δ = +9.0 mV — so a second,
multiplicative effect is also present. Two mechanisms, one cause.

### Mechanism

`.model n4 NMOS(level=54)` gives no parameters at all, so **every** BSIM4
parameter is derived, and the derivation hangs off `TNOM`.

- ngspice: `src/spicelib/devices/bsim4/b4set.c:1950-1951`
  ```c
  if (!model->BSIM4tnomGiven)
      model->BSIM4tnom = ckt->CKTnomTemp;      /* .options tnom, default 27 degC */
  ```
- espice: `src/devices/models/bsim4va.va:3078-3083`
  ```verilog
  /* NOTE: Verilog-A does not support access to the modelcard default Tnom value */
  if (!$param_given(tnom))
      BSIM4tnom = `DEFAULT_TNOM + `P_CELSIUS0;
  ```
  with `` `define DEFAULT_TNOM 25 `` at `src/devices/models/bsim4va.va:44`.

So espice ran the whole BSIM4 parameter set at **Tnom = 25 °C** while the
circuit and ngspice were at 27 °C. The `tnom` *parameter* in the same file
already declares the right default (`bsim4va.va:642`, `MPRcc(tnom, 27.0, "C", …)`);
line 3081 overrides it with the upstream Cogenda constant.

Two consequences, matching the two observed effects exactly:

1. **Weak inversion.** With nothing given, `VTH0` is *derived*
   (`b4temp.c:1493-1497` / `bsim4va.va:4709-4712`):
   `vth0 = type·(vfb + phi + k1·sqrtPhi)` with `vfb = -1.0`, and
   `phi = Vtm0·ln(Ndep/ni) + phin + 0.4` (`b4temp.c:1316-1317`,
   `bsim4va.va:4586`) where both `Vtm0 = KboQ·Tnom` and
   `ni ∝ exp(-Eg0(Tnom)/2Vtm0)` are Tnom functions. 300.15 K → 298.15 K moves
   `phi` by +1.4 mV and `vth0` by ≈ +1.5 mV. Confirmed numerically: forcing
   `vth0` to ngspice's derived 0.16670 in both engines collapses the weak-
   inversion gap.
2. **Strong inversion.** `TempRatio = T/Tnom - 1` (`b4ld.c:1143`,
   `bsim4va.va:6646`) is no longer zero: 300.15/298.15 - 1 = 6.7e-3. `u0`
   picks up `(T/Tnom)^UTE` with `UTE = -1.5` → `×0.99001`, i.e. **-1.0 %** —
   which is the strong-inversion residual.

The Vgsteff block, the Vth block, the pocket-implant/DITS corrections and the
`phi` formula are otherwise **line-for-line identical** between
`b4ld.c:1073-1336` and `bsim4va.va:6570-6858`; I checked them. The 4.8.1/4.8.2
version guards in ngspice (`b4check.c:733`, `b4temp.c:1369`, `b4noi.c:381`) are
`dlcig` clamping and noise only — no DC path. BSIM4 model-version delta is
**not** the cause, contrary to `todo.md`'s note.

### Proof

Adding `tnom=27` to the fixture's model card, nothing else:

```
before: v(d) 0.112496649   max = rms = 1.691e-3   FAIL
after:  v(d) 0.110802997   max = rms = 3.142e-6   PASS (300x margin)
```

and on the parametric probe the weak-inversion deficit goes -4.87 % → **+0.046 %**.

### Fix (written, not built)

`src/devices/models/bsim4va.va:44` — `` `define DEFAULT_TNOM 25 `` → `27`, with
a comment naming ngspice's `b4set.c:1950`. This is the root-cause fix, not a
special case: bsim4va.va was the **only** model in `src/devices/models/` with a
non-27 °C nominal (`bsimsoi_va.va:386` is 27, `mos1.va:49` 27, `mos2.va:86` 27,
`mos3.va:91` 27, `jfet.va:40` 27, `hfet1.va:35` / `hfet2.va:54` / `mesa.va:52` /
`mos6.va:70` 300.15 K = 27 °C). It brings bsim4 in line with the rest of the tree.

Follow-up worth a separate task, not done here: espice has **no** `.options tnom`
plumbing at all (`grep -rn tnom src/**/*.zig` finds only `sweep/temp_sweep.zig`
and the `tnom`→`tref` card alias at `src/builder.zig:456`). Every `.va` hardcodes
27. That is correct for every deck that does not spell `.options tnom`, which is
every deck in the suite, but a deck that does spell it will be silently ignored.

---

## 2. `ngspice/mosamp` — 2.12e-2 / 5.82e-3 — **real espice defect (LTE state granularity)**

### Symptom and worst sample

Worst `max`: `v(5)` at t = 5.8837e-7, ng 13.6070 vs zp 13.1247 (raw 3.54e-2,
2.12e-2 after the edge window).
Worst `rms`: `v(20)`, 5.82e-3.

### Edge or systematic

**Systematic — broad.** `v(20)` has **1580 of 2316** samples over 1e-3 and 262
over 1e-2; `v(66)` 1719/2316; `v(8)` 840/2316. Not a handful of samples. The
error occupies the whole slewing window t ∈ [0.2 µs, 1.7 µs] and again
[5.0 µs, 5.8 µs] — the amplifier's response to the input step and its inverse.
This is not edge phase.

### Mechanism

But it is also not a model error. `.tran 0.1us 10us 0 2ns` in both engines:

```
espice vs ngspice, tmax = 2 ns:   max 3.01e-3   rms 1.37e-4   PASS
```

rms improves **42x**. So both engines converge to the same waveform. Scoring
each default run against that converged reference:

```
ngspice default vs converged:  max 1.90e-2  rms 2.62e-3   (also FAILs the gate)
espice  default vs converged:  max 2.89e-2  rms 3.35e-3
```

**The reference itself is 2.6e-3 rms from the truth.** The 5.82e-3
espice-vs-ngspice rms is roughly the sum of two comparable discretization
errors, not one engine's error.

espice is nonetheless the looser of the two, and that part is a genuine defect.
`ZP_TRAN_STATS=1` on this deck: **206 accepted steps, avg dt 48.5 ns**, against
ngspice's **2316** accepted points (avg 4.3 ns) — 11x. It is not `.options
abstol=10n vntol=10n`: stripping that line leaves espice at 250 steps and
ngspice at 2387 (and *improves* agreement to 1.94e-2 / 1.77e-3, because the
loose abstol floors `del`'s denominator in both).

`stepBound` (`src/analysis/tran/tran.zig:76-155`) is a faithful port of
`CKTterr` (`/tmp/ng/ngspice-44.2/src/spicelib/analysis/cktterr.c`) — same
`volttol`/`chargetol`/`tol`, same divided-difference ladder, same
`trapCoeff[order-1]` = {1/2, 1/12}, same `del = trtol·tol/max(abstol,
coeff·|dd|)` and `sqrt` at order 2. The formula is not the difference; the
**index space it runs over** is.

ngspice calls `CKTterr` once per device **charge state**: MOS2 keeps `qgs`,
`qgd`, `qgb`, `qbd`, `qbs` separately (`mos2def.h`), so 27 MOSFETs give 135
independent candidates. espice's VerA backend emits `D.q` per device
**unknown**, so `qgs+qgd+qgb` arrive *pre-summed on the gate row* — one
candidate where ngspice has three. Summation cancels the divided difference,
`|dd|` drops, `del` grows.

The direction is confirmed with the in-tree oracle. Refining the charge index
space monotonically tightens the step:

| index space | accepted steps | max | rms |
|---|---|---|---|
| per-row (`ZP_NO_QTAPE=1`) | 192 | 2.21e-2 | 6.64e-3 |
| per-device-state (default) | 206 | 2.12e-2 | 5.82e-3 |
| per-`ddt` (ngspice) | 2316 | — | — |

And the cross-fixture pattern confirms the mechanism. The five transient
fixtures split exactly on whether the MOSFETs carry Meyer gate charge at all:

| fixture | model | gate charge | who is closer to converged |
|---|---|---|---|
| mosamp | MOS2, `tox=0.11u cgso=cgdo=1.5n` | live | ngspice 1.3x |
| mos6_inverter | MOS6, `TOX=1.98E-8 CGSO/CGDO` | live | ngspice 1.8x |
| pvt_corners | MOS1, no TOX/CGSO | **zero** (`mos1temp.c:61-62`) | espice 3.5x |
| parallel_inverters_2000 | MOS1, no TOX/CGSO | **zero** | tie |
| hfet_inverter | HFET (`hfet2load.c:231` plain `C·Δv`) | n/a | espice 2.0x |

espice is looser than ngspice on exactly the two decks where the gate charge
is non-zero, and equal or better everywhere else.

### Fix

This is the already-open `todo.md` item **"per-`ddt` LTE states"** under
*Accuracy — documented architectural*. It needs VerA to emit one `D.q` per
`ddt` contribution rather than per device unknown — a device-ABI event. The
host side is already prepared: the per-contribution index space exists
(`engine.buildTapes` writes `rhs_idx[id*n_u + ru]`), `tran.zig:552-560` already
selects `qt_hist` vs `q_hist` by `n_qt`, and `stepBound` is length-agnostic.
No change is proposed here — it cannot be done inside espice.

Do **not** shrink `trtol` to compensate: that is a global tolerance bump and it
would over-refine every deck whose charges are already per-`ddt` (caps,
inductors, diodes, transmission lines all match ngspice's state set exactly
today).

---

## 3. `devices/mos6_inverter` — 3.27e-2 / 2.20e-3

### Symptom and worst sample

Worst: `v(xndinv1.14)` at **t = 8.9606e-10**, ng 1.34007 vs zp 1.46706,
e = 3.269e-2 (raw 3.269e-2 — the edge window did not help). `xndinv1.14` is an
internal node of the series NMOS stack, which has no explicit capacitor.

### Edge or systematic

**Edge-clustered, but at many edges.** Per-variable runs over 1e-3 are all
1-7 samples long and every one sits on a transition:

```
v(xndinv1.14)  4 samples >1e-3 of 315:  t[3.0e-10..4.6e-10] x2, t[8.96e-10..1.20e-9] x2
v(xndinv1.13)  6 samples:               t[4.6e-10..2.0e-9] x6
v(xndinv4.14)  runs at t[5.87e-8..6.12e-8]
v(xndinv2.14)  t[1.77e-8..1.92e-8] x4, t[2.02e-8..2.12e-8] x3
```

ngspice's own grid across the 0→5 V, 2 ns input ramp is
`3e-10, 4.6e-10, 6.35e-10, 8.96e-10, 1.196e-9, 1.611e-9, 2e-9` — seven points
for the whole ramp. The rms of 2.20e-3 is arithmetic on ~6 bad samples out of
315 (`sqrt(6·1e-4/315) = 1.4e-3`), not a spread error.

### Mechanism

`.TRAN 0.5N 150N 0 10P` in both engines:

```
espice vs ngspice, tmax = 10 ps:  max 1.88e-3  rms 2.68e-5   PASS
```

rms improves **82x**. Both converge. Scored against that reference:

```
ngspice default vs converged:  max 2.60e-2  rms 1.19e-3   (FAILs the gate)
espice  default vs converged:  max 3.42e-2  rms 2.15e-3
```

Same story as mosamp, same mechanism (MOS6 with `TOX=1.98E-8` and
`CGSO/CGDO=3.93E-10` → live Meyer charge → summed gate state → looser LTE), and
again the reference is itself over the gate. espice is 1.8x looser.

### Fix

Same as #2 — per-`ddt` LTE states. Nothing fixture-local.

---

## 4. `scaling/parallel_inverters_2000` — 1.17e-2 / 5.83e-4 — **not a defect**

### The GPU question, settled first

- CPU run repeated 3x: **byte-identical** (`md5sum` of the raws matches).
- CPU-only accuracy vs ngspice: **1.173e-2 / 5.832e-4** — i.e. the CPU run
  fails on its own, exactly reproducing the baseline table (which already lists
  identical cpu and gpu numbers).
- GPU vs ngspice: **1.173e-2 / 5.832e-4**, the same to 4 digits.
- GPU vs CPU, raw pointwise: **max 2.27e-14, rms 2.78e-15** — pure fp
  reassociation, 12 orders of magnitude below the failure.
- All 2000 identical inverters carry **identical** error (`v(out1)`,
  `v(out2)`, `v(out1000)`, `v(out2000)` all 8.979e-3 / 5.739e-4). Any
  atomic-order fan-in chaos would break that symmetry.

`todo.md`'s GPU-atomic story is **not** the mechanism here. The FAIL is
independent of the backend.

### Symptom and worst sample

The only variable over the gate is **`i(vdd)`**: max 1.173e-2 at
**t = 5.15932e-9**, 6 samples over 1e-3, 1 over 1e-2. `v(out*)` peaks at
8.979e-3 (under the 1e-2 max gate) with rms 5.739e-4 (under the 1e-3 rms gate).
So the fixture fails on **one sample of one variable**, by 17 %.

### Edge or systematic

Edge. t = 5.159 ns is inside the input's 100 ps fall (5.1 → 5.2 ns). The two
grids there:

```
ng  ... 5.12768e-9   5.15932e-9   5.20000e-9 ...   i(vdd): -3.6e-9, -0.04090, -0.35899
zp  ... 5.12625e-9   5.15626e-9   5.20000e-9 ...   i(vdd): -3.6e-9, -0.02957, -0.35888
```

Same shape, grids 3 ps apart, and both engines jump ~330 mA across a 44 ps gap.
The comparator linearly interpolates espice at ngspice's t and gets -0.0526 vs
-0.0409: 11.7 mA of **linear-interpolation error on a curved 360 mA spike**,
divided by `denom = max(peak, span, 1) = 1.0` because the current never exceeds
1 A. The ±w 9-point rescan lands on -0.0526 and -0.0218 and cannot do better.

### Proof

`.tran 0.1n 6n 0 2p` in both engines:

```
espice vs ngspice, tmax = 2 ps:  i(vdd) max 3.86e-6   rms 7.18e-8   PASS
```

max improves **3000x**. Against that reference:

```
ngspice default vs converged:  max 3.77e-2  rms 3.13e-3
espice  default vs converged:  max 4.11e-2  rms 3.07e-3
```

A tie — both defaults are ~3e-3 rms from truth, both would FAIL the gate
against it.

### Fix

None in the engine. See "What to actually change" below.

---

## 5. `vacask/mul` — 1.69e-2 / 8.35e-5 — **not a defect**

### Symptom and worst sample

Only `i(vs)` fails, on **max** only: 1.692e-2 at t = 4.6367e-6 (ng 1.46123 vs
zp 1.54095). rms 8.35e-5 passes at **12x margin**. 202 of 500 017 samples
exceed 1e-3 (0.04 %), 6 exceed 1e-2, in scattered runs of 1-5. Every node
voltage is ≤ 8.8e-5 (`v(2)` 8.82e-5, `v(3)` 8.31e-5, `v(1)` 1.99e-5).

### Edge or systematic

Edge — diode turn-on. But the *cause* of the edge mismatch is a fixed grid
phase, not LTE.

The deck is `.tran 0.01u 5m 0 0.01u` with `method=gear maxord=2`. `tmax = 10 ns`
**pins the step**: `ZP_TRAN_STATS` reports `accepted=500024, avg_dt=1.000e-8,
rej[lte=6]` — LTE fires 6 times in half a million steps. Both engines march a
fixed 10 ns grid, and the grids are **2.47 ns out of phase**:

```
ng  4.60672419e-6, 4.61672419e-6, 4.62672419e-6, ...
zp  4.60919378e-6, 4.61919378e-6, 4.62919378e-6, ...
```

The offset is set during the startup doubling ladder before `tmax` takes over.
ngspice doubles cleanly (1e-10, 1e-10, 2e-10, 4e-10, 8e-10, 1.6e-9, 3.2e-9,
6.4e-9, then LTE at 4.21e-9); espice's LTE bites one step earlier (its 3rd step
is 1.019e-10, not 2e-10) and the residue never washes out because nothing
afterwards is free to re-phase.

`i(vs)` is `100·(v(a) − v(1))` across `r1 = 0.01` — a 100x-amplified node
difference with a hard diode-conduction knee, so a quarter-grid phase offset on
a curve rising 0.43 A per step reads as 0.08 A.

I checked and **rejected** a plausible-looking gear defect: `stepBound`
(`src/analysis/tran/tran.zig:126`) hardcodes `coeff = 1/12` at order 2, which is
ngspice's `trapCoeff[1]`; ngspice uses `gearCoeff[1] = 0.2222…` for GEAR
(`cktterr.c:23-35, 58-66`), a 1.63x looser step for espice on any `method=gear`
deck. Real divergence, cited, and worth fixing — but **not** the mechanism here,
because `tmax` dominates: forcing the equivalent (`trtol=2.625`, i.e. `7·(1/12)/(2/9)`)
changes espice from 500 024 to 500 069 accepted steps and nothing else.

### Proof

Same 20 µs window, both engines:

```
tmax = 10 ns (deck default):  i(vs)  max 1.692e-2   rms 6.30e-4   FAIL
tmax =  1 ns:                 i(vs)  max 5.67e-4    rms 1.06e-5   PASS
```

30x on max, 60x on rms.

### Fix

No engine fix for the FAIL. One unrelated correctness fix is warranted and is
*not* a fixture special case: `src/analysis/tran/tran.zig:126` (and the scalar
tail at `:148`) should select `2.0/9.0` when the integration method is gear at
order 2, matching `cktterr.c:58-66`. Left unwritten here because it needs the
method to be threaded into `stepBound` and it changes the grid on every
`method=gear` deck in the suite — a separate, measurable step.

---

## 6. `devices/hfet_inverter` — 3.18e-2 / 2.85e-3 — **not a defect; ngspice is worse**

### Symptom and worst sample

`v(4)` (second inverter output), **t = 1.0900496e-9**, ng 1.55372 vs zp 1.22717.
Raw error 1.635e-1, 3.176e-2 after the edge window.

### Edge or systematic

**Edge, one edge, unambiguously.** 8 samples of 323 over 1e-3 on `v(4)`, in a
single contiguous run `t[1.0788e-9 .. 1.1276e-9]` — 49 ps wide. 3 samples over
1e-2. `v(3)` likewise: 7 samples, one run, same window. `v(1)`, `v(2)` exactly
zero error; `i(vdd)` 2.23e-4 max; `i(vin)` 6.86e-5 max.

The window is where ngspice's own grid collapses from 10 ps to 1.25 ps, so the
comparator's `w = max(dt_lo, dt_hi, dt_cand)` is *smaller* there than the real
phase offset — which is why the rescan does not cancel it.

### Proof — and the direction of the error

`.tran 0.01n 3n 0 2p`:

```
espice vs ngspice, tmax = 2 ps:  max 8.79e-4  rms 4.15e-5   PASS
```

max improves 36x, rms 69x. Now the edge phase, measured as the time `v(4)`
crosses 1.0 V:

```
converged (tmax=2p):  ngspice 1.087382 ns   espice 1.087370 ns   (12 fs apart)
default grid:         ngspice 1.077768 ns   espice 1.086682 ns
                      ngspice is 9.61 ps early;  espice is 0.70 ps early
```

**espice's default grid times this edge 13.7x better than ngspice's.** Scored
against the converged reference:

```
ngspice default vs converged:  max 8.73e-2  rms 3.03e-3
espice  default vs converged:  max 3.82e-2  rms 1.53e-3
```

This reproduces `todo.md`'s claim independently (it said 1.0874 ns, 0.7 ps and
9.6 ps — correct).

### Fix

None. The metric is scoring ngspice's grid phase, and ngspice is the worse of
the two engines on this deck.

---

## 7. `ensemble/pvt_corners` — 9.07e-2 / 3.92e-3 — **not a defect; ngspice is unphysical**

Not a corner sweep (see the corrections at the top). One rise event and one
fall event, each appearing twice because the pulse period is half the run.

### Symptom and worst samples

Two distinct failures, on two different nodes:

**(a) `v(o2)`, max 9.074e-2 at t = 1.0048757e-6** (ng 3.00054 vs zp 1.75855,
raw 3.764e-1). `o1` and `o2` have **no capacitance at all** —
`mos1temp.c:61-62` sets `MOS1oxideCapFactor = 0` when TOX is not given, and the
deck gives no TOX and no `CGSO/CGDO/CGBO`, no `CJ`, no `CBD/CBS`. The only
capacitor in the circuit is `CL = 100f` on `out`. So `o1` and `o2` are
**algebraic** — a DC map of `v(in)` — and `o2`'s transition is a step. espice
resolves it (its dt collapses to ~1 fs across the fall: 6.01511115e-6 →
6.01511222e-6 is 1.07 fs); ngspice steps *over* it — its grid goes
1.003 µs → 1.00488 µs → 1.00627 µs, three points for the whole step. The
comparator's rescan samples espice at 9 points across ±1.88 ns and steps over an
80 ps transition.

**(b) `v(out)`, max 6.518e-2, rms 3.922e-3 — the actual rms driver.**
40 of 2064 samples over 1e-3, in four runs of 8/12/8/12 (= two events × two
periods). Runs on the fall are 35 ns wide, far wider than the 10 ns input fall.
Dumping the window shows why:

```
ng  6.01924e-6: 3.4562696   <-- 4.7 % ABOVE the 3.3 V supply rail
    6.02000e-6: 3.1902881
    6.02048e-6: 3.3122721
    6.02111e-6: 3.2925037
    6.02213e-6: 3.3055210   ... decaying ±4 mV ring
zp  6.01571e-6: 3.3010726   ... decaying ±0.4 mV ring
```

That is trapezoidal ringing after the near-discontinuous drive, an order of
magnitude worse in ngspice because its step at the event was 2.45 ns against
espice's ~1 fs.

### Edge or systematic

Edge on `v(o2)`; **integration artifact in the reference** on `v(out)`.

### Proof

`.tran 10n 20u 0 100p`:

```
espice vs ngspice, tmax = 100 ps:  v(out) 6.52e-3   v(o1) 4.84e-4   v(o2) 1.21e-6
                                   WORST max 6.52e-3  rms 2.42e-5   PASS
```

`v(o2)` improves from 9.07e-2 to **1.21e-6** — 75 000x.

Peak `v(out)` over 6.01-6.06 µs:

```
converged:        ngspice 3.299999997   espice 3.299999997   (no overshoot)
default grid:     ngspice 3.456270      espice 3.301073
```

**ngspice's default trace overshoots its own 3.3 V supply by 156 mV; espice's
by 1.1 mV.** Edge phase of `v(o2)` crossing 1.65 V:

```
converged:    1.004899669 µs  (both engines, 10 digits)
default:      ngspice 1.004031457 µs (868 ps early);  espice 1.004873063 µs (26.6 ps early)
```

espice is **33x** better. And scored against the converged reference:

```
ngspice default vs converged:  max 8.73e-2  rms 8.79e-4
espice  default vs converged:  max 5.82e-2  rms 2.53e-4
```

espice is **3.5x closer** on rms. The worst `max` in the whole suite is
measuring ngspice's error, not espice's.

### Fix

None in the engine. Optionally rename the fixture or add the corner sweep its
comment promises — it currently tests neither PVT nor lanes.

---

## What to actually change

**Written (one line, plus its comment):**

- `src/devices/models/bsim4va.va:44` — `DEFAULT_TNOM` 25 → 27.
  Verified: `devices/bsim4` 1.69e-3 → 3.14e-6. Not built; the FastVAF `.so`
  cache will re-key on the model hash.

**Open, already tracked, needs VerA (not espice):**

- per-`ddt` LTE charge states. Owns `ngspice/mosamp` and
  `devices/mos6_inverter`, and is the only mechanism in this audit where espice
  is measurably the looser engine. `todo.md` *Accuracy — documented
  architectural*.

**Open, real, unrelated to any of the 7:**

- `src/analysis/tran/tran.zig:126` and `:148` use `trapCoeff[1] = 1/12` at
  order 2 regardless of method; `cktterr.c:58-66` uses `gearCoeff[1] = 2/9` for
  GEAR — espice's gear-2 step is 1.63x looser than ngspice's. Found while
  auditing `vacask/mul`; not the cause there (tmax dominates), but it is wrong
  on every `method=gear` deck.

**Not a code change — a harness one, and the honest reading of five of seven:**

`hfet_inverter`, `mos6_inverter`, `pvt_corners`, `parallel_inverters_2000` and
`mosamp` all share one fact: **ngspice's default-grid trace is itself 1e-3 to
3e-3 rms away from the converged answer** — over the gate it is being used to
enforce. Measured, per fixture, above. The comparator is scoring grid phase
against a reference that has not converged, and on two of the five the
reference is the worse engine (one of them overshoots its own supply rail).

The root-cause fix is on the reference side, not the tolerance side: for a
fixture whose reference trace is not grid-converged, generate the reference at a
tightened `tmax` (one extra cached reference run per fixture) and score **both**
engines against that. Uniform, no per-fixture constants, no tolerance change,
and it turns the metric back into "is the physics right" instead of "did you
guess ngspice's timestep". The cheap variant — adding an explicit `tmax` to the
five decks — gets the same numbers for far less work but silently stops testing
default step control, which is the thing that actually differs.

Either way, **do not** widen the gate. The gate is correctly calibrated for the
149 fixtures where the reference *is* converged.
