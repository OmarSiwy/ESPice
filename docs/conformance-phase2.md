# Conformance phase 2: root causes and fix recipes

Root-cause digs against ngspice 44.2 for the decks indexed in `issues.md`
section F. Group numbers are the r-conformance root-cause groups. Deck
pass/fail status lives in `issues.md`; this page keeps the cause, the
ngspice reference and the recipe, and names the commit where a recipe
landed. The topical docs carry the resulting behavior:
[transient-integration](analysis/transient-integration.md),
[operating-point-homotopy](analysis/operating-point-homotopy.md),
[dc-sweep](analysis/dc-sweep.md),
[pss-shooting-harmonic-balance](analysis/pss-shooting-harmonic-balance.md),
[mpde-envelope](analysis/mpde-envelope.md) and
[devices/models](devices/models.md).

Every recipe here changes output bytes, so each one lands as its own commit
with the before/after deck list. The gate: no passing deck starts failing,
and every changed deck moves toward its reference or has its reason recorded.

## Group 1: first transient step (issues F1). Landed

Two defects against dctran.c, each hitting three decks.

- (a) The t = 0 breakpoint clamp lost the `firsttime` /10. ngspice sets
  `delta = min(tstop/100, tstep)/10` (dctran.c:134), clamps it to maxStep
  (546-547), clamps again to `0.1*min(saveDelta, breaks[1]-breaks[0])` at
  t = 0 (578-579), and only then divides by 10 for `firsttime` (581-586).
  The `MAX(delta, 2*delmin)` at 592-595 is `#ifndef XSPICE` and absent from
  44.2.
- (b) The first accepted dt repeats without CKTtrunc for every circuit, not
  only circuits with charge (dctran.c:847-862). CKTtrunc returns
  `MIN(2*delta, timetemp)` (ckttrunc.c:53, 183) from the second accepted
  step on.

Landed in `e16462d`. First steps now equal ngspice's on all six decks.
Still open: `tran/bench_ngspice_mosamp` publishes far fewer points than
ngspice later in the run; that is F9's LTE behavior, not the first step.

## Group 5: VBIC (issues F4)

**(a) Self-heating on a 4-terminal card. Landed in `23946b5`.** ngspice
enables self-heating whenever RTH > 0 (vbicsetup.c:471-480), but ties a
missing fifth (thermal) terminal to ground (inp2q.c:85-87), so a 4-node card
runs at dT = 0. The builder defaults `sw_et = 0` when the card has fewer than
five nodes; an explicit `SW_ET` on the card still wins.

**(b) Noise at M=2. Landed in `a6a1a1b`.** The VA scaled currents by
`MFACTOR_USE` and then multiplied the noise sources by it again, so noise
scaled as M^2 where ngspice scales it as M.

Open residual, also at M=1: 0.9% at 100 MHz. ngspice puts the RBP thermal
noise between emitEI and emit (vbicnoise.c:122, which looks like an ngspice
bug); the VA puts it on bp-cx. CJCP=0 removes the gap and RBP=4e6 shrinks it
to 0.1%. To match ngspice, contribute the rbp noise on `b_re`'s nodes.

**(c) `i(q1)` (E9). Landed in `23946b5`.** ngspice creates an excess-phase
inductor branch only when TD > 0 (vbicsetup.c:510-525). Node xf2 carries only
the 1 ohm load, so the branch current equals V(xf2), and in ngspice's raw
file `i(q1)` equals `v(q1#xf2)` exactly. The builder aliases `i(q1)` to the
xf2 node when TD > 0.

Open: `dc/device_vbic_forced_output` row 25 (the Vc = 3.45 V zero crossing
of `i(vb)`) is about 1e-6 relative off. GMIN=0 removes 7e-12 of the 3.8e-11
gap (ngspice puts gmin on Irci, the VA on Igcx). The rest is plausibly the
physical constants: the VA uses NIST 2004 values, ngspice vbicload.c:1660
uses 1.380662e-23 and 1.602189e-19. Unverified.

## Group 6: operating point on `stress/scaling_inverter_chain_4k` (issues F5). Landed

ngspice solves this OP with dynamic gmin stepping (768 iterations). espice's
gmin sequence matched ngspice's until a step where ngspice took the slow-down
branch and espice did not, because espice ran the stepping rungs with the
itl1 cap (100) and thresholds instead of itl2 (50). Newton then accepted a
wandering 79-iteration solve with |F| = 0.44 A, every later gmin step built
on it, and the final OPtran rung reported the settled transient as success.

Landed in `557d833` and `ee748c7`:

1. The gmin and source-stepping rungs run Newton with `itl2`, and the gmin
   rung uses `itl2/4` and `3*itl2/4` as its easy and hard thresholds
   (cktop.c:194, 211-215). The final clean solves keep `itl1`, as ngspice's
   `NIiter(ckt, iterlim)` does (cktop.c:264).
2. cktop.c:215-222: above 3/4 of the cap the factor becomes
   `max(sqrt(factor), 1.00005)`; the final clamp sets
   `factor = gmin_val/gtarget` before `gmin_val = gtarget`.
3. Source stepping breaks at once when the lambda = 0 solve fails; retrying
   the same cold solve did nothing.
4. OPtran returns the confirming Newton's verdict instead of success.

The 4k chain now finishes on the gmin rung with the right OP, in 15 s
instead of 308 s. The deck still fails in the transient (F9).

## Group 8: OP Newton acceptance (issues F7). Findings only

`tran/bench_tline_ltra1_1_line` and `txl1_1_line` publish v(2) = 5.005 V over
a 5 V supply. The residual gate (`residualConverged` in
`src/solver/converger.zig`) accepts
`|f_i| <= max(residual_tol, 10 * diag_i * (reltol*|x_i| + vntol))`: a voltage
tolerance scaled by the row's diagonal conductance, about 1.5e-4 A on these
rows. ngspice's NIconvTest checks the current as
`reltol*max(|I_new|, |I_old|) + abstol`. Changing the gate is global and
needs its own full-corpus A/B.

## Group 9: envelope (issues F8). Landed

- 9a, `30b509b`: columns were named from node names and ignored the probe
  labels, so a branch-current probe (`i(vin)`) was published as `v(2)`.
- 9c, `30b509b`: the window RMS counted both endpoints (65 samples over 64
  steps, sqrt(64/65) low). It now uses trapezoid endpoint weights.
- 9b, `74df137`: the envelope was quasi-static (C open, dt = 0), so
  `rc_startup_0p001` published v(out) = v(in). Every envelope step is now a
  trapezoid companion step carrying the charge history, seeded at the DC
  operating point and saved and restored on each rollback.

## Group 10: PSS DC offset (issues F10). Landed in `6ccb2a7`

Zeroing the trapezoid `i_prev` at every period start lost dt*i0/2 of charge
per period; on the RC decks the steady mean offset is -(i0*R)/(2N), which
matched the measured offsets to three digits. The seed is now
`i_prev[i] = -rhs[i]` (the static residual at x0) on rows with a nonzero
diagonal C entry, 0 elsewhere. A converged trapezoid step always leaves
`i_prev = -rhs(x_new)`, and the seed is a function of x0, so it sits inside
the finite-difference shooting Jacobian and Newton stays quadratic. The mask
matters: unmasked, algebraic rows ring as +-f(x0) and make the Jacobian near
singular.

Rejected: backward Euler for the first step of each period (fails
`rc_minimal_grid` at 3.17x and `rc_slow_settling` at 1003x), and carrying
`i_prev(T)` from the previous base integration (a Picard update that
contracts at exp(-T/tau) per iteration, about 0.999 on `rc_slow_settling`).

pnoise's own period walk solves quasi-statically at each sample, with no
charge history, so the seam fix does not apply there.

## Group 13: device DC physics (issues E6)

Each cause was confirmed by a parameter experiment in both simulators.

| Deck | Cause | ngspice reference | Landed |
|---|---|---|---|
| `dc/device_bsim1` | K1 and K2 not clamped at 0 | b1temp.c:124-125 | `167495c` |
| `dc/device_hisim2` | LP (pocket length) defaults to 15 nm when CODEP = 0 in HiSIM 2.80, which ngspice 44.2 forces | hsm2set.c:236 | `c53e9f3` |
| `dc/device_bsim2` | weak inversion (Vgst <= Vglow) is a closed form with no Uvert/U1/Kk/Aa | b2eval.c:337-343 | `04b35bd` |
| `dc/device_bsim2_ngspice` | Vc was clamped at 0; b2eval.c leaves it free and U1s is negative at deep Vbs | b2eval.c | `04b35bd` |
| `dc/device_mesa_output` | old physical constants and PHIB default | ngspice 44 const.h; PHIB = 0.5*CHARGE | `4504f44` |
| `dc/device_vdmos_output` | gmin between d' and s'; ngspice uses m/RDS, or 1e-15 S without RDS, and puts gmin only on the body diode | vdmosset.c:292-299, vdmosload.c:808 | `9d7d7d6` |

`dc/device_mesa_inverter` (row 48, 1e-3 relative at the steepest point) and
`tran/device_mesa_oscillator` (OP 17% off) belong to the same model and
should be rechecked against the mesa change; see `issues.md` E6 for their
status.

## Group 15: oracle defects (issues F11). Decided

Each deck failed against an oracle that was wrong or tested something other
than the deck's name. The user chose an option per deck; `0243d0b`
regenerated the oracles, and each oracle's `oracle.derivation` records what
it is now. No oracle generator lives in the repo.

- `tran/bench_tran_sffm_source`: back on ngspice 44.2's own run at the
  original tolerances. ngspice reads the card as (VO VA FM MDI FC) and limits
  MDI to FC/FM (vsrcload.c:235-259), so this card is a 10 kHz carrier at
  MDI = 0.1, modulated at 100 kHz. `vsource.va` and `isource.va` read SFFM
  the same way, and the deck passes.
- `dc/bench_mosfet_cmos_inverter`: the inverter was exactly balanced, so
  vin = VDD/2 was metastable and each simulator reported where its Newton
  stopped. The deck now has LAMBDA=0.01 on both models and its oracle is
  ngspice at reltol=1e-9.
- `convergence/bench_ota_cutoff_abstol`: every branch current sat at 1.4x
  abstol and the oracle was ngspice's stopping point inside the tolerance.
  The deck now carries `.options abstol=1e-18 reltol=1e-10 vntol=1e-12` and
  its oracle is ngspice at those options.
- `sens/bench_sens_bridge`: 22 of 24 oracle columns were ngspice resistor
  parameters with sensitivity exactly 0. Restricted to `v(r1)`..`v(r5)` and
  `v(vin)`.
- `multi_analysis/bench_sens_diffpair`: ngspice 44.2 writes the second
  `.tf` plot first, and both plots share one name. The oracle now keeps deck
  order, and its sensitivity columns are restricted to the principal R and V
  columns and q1/q2 ISE/ISC. The dropped columns were ngspice finite
  difference noise or artifacts (`ikf` at 0 means infinite, so ngspice's
  perturbation changes nothing; RB is perturbed without re-deriving RBM).
- `dc/device_mesa_inverter` was not an oracle defect: it moved to group 13.
