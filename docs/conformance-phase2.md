# Conformance phase 2: fix recipes

Read-only root-cause digs done on 4614f9a (-Dgpu=false build) against
ngspice 44.2, for the agent that implements phase 2. Line numbers are at
4614f9a; the drivers/engine/frontend refactors running beside this work will
move them, so every recipe also says what the change is. Group numbers are
the r-conformance root-cause groups; the matching `issues.md` entries are in
its section F index.

Every recipe here changes output bytes, so each one lands as its own commit
with the before/after deck list (gate: no passing deck fails, every changed
deck moves toward its reference).

## Group 1: first transient step against ngspice dctran.c

Both defects are real, and each of the six decks has exactly one of them.
Evidence: accepted time grids of espice-4614 and ngspice 44.2 on all six.

**(a) Confirmed: the breakpoint clamp skips the `firsttime` /10.** Decks with
charge and a source edge near t = 0: `tran/bench_medium_rc_ladder_50`,
`tran/bench_ngspice_mosamp`, `tran/bench_power_buck_open`.
dctran.c:134 sets `delta = min(tstop/100, tstep)/10`; 546-547 clamp it to
maxStep; at t = 0 (always `breaks[0]`) 578-579 set
`delta = min(delta, 0.1*min(saveDelta, breaks[1]-breaks[0]))`, saveDelta =
tstop/50 (318); only then 581-586 divide by 10 for `firsttime`. The
`MAX(delta, 2*delmin)` at 592-595 is `#ifndef XSPICE`, absent from 44.2.
`tran.zig:544-547` divides by 100 first and then, when `bp0 < dt`, sets
`dt = bp0/10`, losing the final /10 whenever the breakpoint binds.
First step, espice vs ngspice: rc_ladder 1e-10 vs 1e-11, mosamp 1e-9 vs
1e-11, buck_open 1e-9 vs 1e-10.
Recipe (544-547): `dt = min(min(dt_init, t_stop/100)/10, effective_dt_max)`;
if a next breakpoint `bp0` exists, `dt = min(dt, 0.1*bp0)`; then `dt /= 10`.
The saveDelta operand never binds (the first operand is <= tstop/1000). The
t_start clamp stays after it. Expected: first step equal to ngspice's on all
three decks.

**(b) Half done: the `firsttime` no-CKTtrunc repeat only runs with charge.**
`if (steps == 0) dt_next = dt;` (692-694) sits inside `if (has_charge)`;
charge-free circuits keep `dt_next = min(2*dt, max)` from 677. dctran.c:847-862
jumps to `nextTime` on `firsttime` without CKTtrunc, so delta repeats;
CKTtrunc returns `MIN(2*delta, timetemp)` (ckttrunc.c:53/183) from the second
accepted step on. Charge-free decks: `multi_analysis/bench_ngspice_res_array`
1e-12, 3e-12, 7e-12 vs ngspice 1e-12, 2e-12, 4e-12; `tran/bench_tline_delay_line`
2e-13, 6e-13 vs 2e-13, 4e-13; `tran/bench_tline_cpl_ibm2` 1e-12, 3e-12 vs
1e-12, 2e-12; after that each grid stays one first-dt off.
Recipe: at 677 `dt_next = if (steps == 0) dt else @min(dt * 2.0,
effective_dt_max)` (the boundStep min stays after it); in the has_charge
block drop the `steps == 0` branch and wrap the LTE code in `if (steps > 0)`.
Expected: res_array, delay_line, cpl_ibm2 on ngspice's grid point for point.

Not explained by (a) or (b): mosamp publishes 207 points against ngspice's
2316, later in the run. Needs its own dig after (a) lands; re-measure the
group-14 drift decks after both land too.

## Group 5: VBIC (4 decks)

**(a) Self-heating on a 4-terminal card: confirmed.** ngspice turns
self-heating on whenever RTH > 0 (`vbicsetup.c:471-480`), but VBIC's fifth
(temperature) terminal is tied to ground when the card omits it
(`inp2q.c:85-87`), so a 4-node card runs at dT = 0. Ours: `dt` is an internal
node (`vbic13_4t.va:784`), never grounded, and `sw_et` defaults to 1 (`:826`),
so the temperature floats.
Evidence: with RTH=300 removed from espice's copy, `dc/device_vbic_temp`
matches every column but `i(q1)`; `multi_analysis/device_vbic_ce_amp` AC goes
from 257/257 failing rows to 0/257; `dc/device_vbic_forced_output` drops to
1/261.
Recipe: `src/frontend/builder.zig:1412` (`addSingleDevice`), right after
`var model: D.Model = .{};`, add
`if (comptime @hasField(D.Model, "sw_et")) model.sw_et = 0;` with the
inp2q.c reference. Only vbic has the field; `applyKv` runs later, so an
explicit `SW_ET=1` still wins. Confirmed in `inp2q.c:85-87` ("tie missing
ports to ground, (substrate and thermal node)"). A card that DOES name the
fifth node keeps self-heating in ngspice, so gate the default on the card's
node count (< 5) where the builder sees it.
Remaining `forced_output` row 25 (3.26x, the Vc = 3.45 V zero crossing of
`i(vb)`): about 1e-6 relative. GMIN=0 removes 7e-12 of the 3.8e-11 gap
(ngspice puts gmin on Irci, the VA on Igcx); the rest is plausibly the
constants (VA: NIST2004; ngspice `vbicload.c:1660`: 1.380662e-23 /
1.602189e-19). Unverified.

**(b) Noise at M=2: pinned to a double mfactor.** `M=2` reaches the VA's own
`m` parameter (`instance.mfactor` stays 1). The VA scales currents by
`MFACTOR_USE` (`:1596-1617`) and then multiplies the noise sources by it
AGAIN (`:1723-1737`), so they scale as M^2; ngspice scales them as M (its
`SCALE = area*m` is already inside the stored currents).
Measured espice/ngspice at M=2: 1.045 (1 MHz), 1.047 (10 MHz), 1.17
(100 MHz); at M=1: 1.000 up to 10 MHz, 1.009 at 100 MHz. Doubling only the
M^2 terms of ngspice's per-source breakdown predicts 1.0452 / 1.0469 / 1.157.
Recipe (`models/vbic13_4t.va` noise block): drop the leading `MFACTOR_USE`
from the shot terms Ibe, Ibex, Itzf, Ibep, Iccp; rci becomes
`4kT*(abs(Irci)+MFACTOR_USE*1e-10*Gci)/(abs(Vrci)+1e-10)`; Ibep flicker keeps
one `MFACTOR_USE`, not two. (`vbic13_4t.va` is not on the phase-1 ownership
list; check before editing.)
Residual 0.9% at 100 MHz, also at M=1: ngspice puts RBP thermal noise between
emitEI and emit (`vbicnoise.c:122`, looks like an ngspice bug); the VA puts it
on bp-cx. CJCP=0 removes the gap, RBP=4e6 shrinks it to 0.1%. To match
ngspice, contribute the rbp noise on `b_re`'s nodes.

**(c) E9, `i(q1)`: confirmed.** ngspice's excess-phase inductor branch,
created only when TD > 0 (`vbicsetup.c:510-525`). Node xf2 carries only the
1 ohm load (`Ixxf_Vrxf = 1*SCALE`), so the branch current equals V(xf2);
in ngspice's raw `i(q1)` == `v(q1#xf2)` exactly. The VA has the same
second-order transfer and its V(xf2) = Itzf*M, the same quantity in DC, AC
and transient.
Recipe: `NetBuilder.addByLetter` (`builder.zig:1157`), after
`addSingleDevice`: `if (id == .vbic13_4t and td > 0) try
self.addBranchProbe(dev.name, self.b.n - 1);`, `td` from the card kv falling
back to the model card. Works because xf2 is the last internal node and
vbic13_4t has no collapse step (row n-1); `prepare.zig` already remaps
`nb.br` rows through the permutation.
`device_vbic_ce_amp`: after (a) and (c) only B3 (PZ ports) remains.


## Group 6: OP false success (`stress/scaling_inverter_chain_4k`)

**(1) Confirmed: OPtran returns success when the confirming Newton failed.**
`op.zig:282-287`: a failed `fin` restores `x_settled` and still returns
`.converged = true`. ngspice 44.2 has no OPtran rung unless `optran` is given
(cktop.c:94-97).
Recipe: return `.converged = fin.converged` at 287, drop the comment at
243-246, keep the `needs_tran_op` early return at 268. Land it AFTER (2), or
the 4k deck goes from wrong output to an error.

**(2) The stepping ladder gives up because its Newton cap is itl1, not itl2.**
ngspice does not solve this OP with plain Newton either: with `.option acct`
and `ngdebug` it runs dynamic gmin, 768 iterations, v(s1) = 1.8,
v(s2) = 5.4e-9. espice's plain Newton fails from N = 30 up (dx = 4.7e234 at
s100), which is ngspice behaviour. The gmin sequences agree step for step
through 2.2029e-4 and 2.1199e-4; then:
- espice's 2.1199e-4 step took 37 iterations. ngspice takes the slow-down
  branch there (`iters > 3*dcTrcvMaxIter/4`, dcTrcvMaxIter = itl2 = 50,
  cktop.c:194, 211-215), shrinks the factor and tries 2.0796e-4.
- espice runs these solves with itl1 = 100 and uses 100 in its thresholds
  (op.zig:114, 140, 142, via `newtonRun` -> `optionsFromTolerances(tol,
  null)`): 37 < 75 counts as easy, it keeps factor 1.039 and jumps to
  2.040e-4, the fold, which had already failed twice.
- At 2.040e-4 the first Newton step is dx = -1.9e32; Newton wanders 79
  iterations (ngspice's cap of 50 would reject it) and is accepted with
  |F| = 0.44 A and I(Vdd) = 1.7e4 A: the relative dx test on a huge branch
  current is far too loose. Every later gmin step "converges" on that, x
  grows as 1/gmin to I(Vdd) = 4.5e12 A at gmin = 1e-12, the clean gmin = 0
  solve fails SingularMatrix and breaks (132) into rung 3.
- Rung 3 cold-starts at lambda = 0, fails SingularMatrix exactly like plain
  Newton, and retries the same lambda = 0 start 12 times until
  delta < 1e-4 (187-196). gillespie_src (cktop.c:516-545) runs a gmin
  sub-ladder for the zero-source solve instead. JFNK fails, rung 5 returns
  the settled transient as success.
The 2400/3000-stage chains pass by luck (3000 took 70 iterations, also over
ngspice's cap). The 100-solve caps at 113 and 165 were not what failed.

Recipes, in order:
1. `newtonRun` takes an optional iteration cap; the gmin rung (114) and the
   source rung (169) pass `options.tol.itl2`; 140/142 use `itl2/4` and
   `3*itl2/4`. The final clean solves (125, 205) keep itl1, as ngspice's
   `NIiter(ckt, iterlim)` (cktop.c:264). Expected (unverified, no rebuild was
   allowed): ch4000 follows ngspice's sequence (2.0796e-4 next) and finishes
   on the gmin rung.
2. cktop.c:215-222 small cases: above 3/4 of the cap,
   `factor = @max(@sqrt(factor), 1.00005)`; on the final clamp set
   `factor = gmin_val/gtarget` before `gmin_val = gtarget`.
3. Rung 3: when lambda = 0 fails with no good point yet, run the gillespie
   gmin sub-ladder at lambda = 0 (diag gmin*1e10, /10 for 11 steps, then 0) or
   `break` at once; the 12 identical retries do nothing.
4. Then the honest-failure fix (1).
Traces: scratchpad `c/rB/ch4000_e.log` (espice), `c/rB/ch4000c.log` (ngspice).


## Group 9: envelope (`envelope/sine`, `envelope/rc_startup_0p001`)

**9a. One column is mislabeled; the columns are not shifted.**
`src/analysis/tran/envelope.zig:304-314` names columns from
`ctx.circuit.nodeName(node)` and ignores `ctx.probe_labels`. `prepare.zig:147-160`
orders branch-current probes first, and a branch row has no node name, so
`i(vin)` is published as `peak(v(2))`/`rms(v(2))`. It holds 0.002 A in `sine`
and 0 in `rc_startup`.
Recipe: build the names with `root.probeNames(ctx, "time")` (`types.zig:27`,
which already prefers `probe_labels` and falls back to `v(<name>)`/`v(<row>)`)
and wrap each one as `peak({s})`/`rms({s})`.

**9b. `rc_startup_0p001` needs the capacitor's history.** `peak(v(out))`
equals `v(in)` because the envelope is quasi-static: `newtonAt`
(`envelope.zig:46-63`) solves with A = G and dt = 0, so C is open and
v(out) = v(in) (1 / 0.7016 published). The oracle is the exact RC sine-startup
response.
Recipe: make the steps in `coarseAdvance` (233-249) and in the fine loop
(164-183) real trapezoid companion steps, reusing `PeriodHook`
(`pss.zig:126-164`) with alpha = 2/dt per step. dt may change between the 4x
coarse and fine steps because trapezoid is one-step. Seed `q_prev = q(x_op)`,
`i_prev = 0` once at t = 0 (exact at a DC operating point), carry both across
every step, and save/restore them with `x_outer_save` on each rollback (lines
125, 151, 187).
Expected (Python trapezoid model, dt = T/64): `rc_startup_0p001` [0,1 ms]
peak 0.25418 vs 0.25448, RMS 0.15077 vs 0.15089; [4,5 ms] peak 0.15871 vs
0.15894, RMS 0.11107 vs 0.11116. All inside rtol 1%. `rc_startup_1e-05` still
passes (0.99740/0.70570 vs 0.99803/0.70573).

**9c. RMS 0.77% low: both window endpoints are counted.**
`envelope.zig:158-162` seeds `sum_sq` with the window-start sample and sets
`n_samples = 1`, then the loop adds all 64 step samples: 65 samples, both
endpoints, divisor 65. For a periodic sine that is
A/sqrt(2)*sqrt(64/65) = 1.403293, exactly the published value.
Recipe: trapezoid weights. Start `sum_sq = 0.5*v0^2`, add every step's v^2,
subtract `0.5*v_last^2` after the loop, divide by the step count
(`n_samples - 1`). Keep the start sample in `peak`. Optional: drive the fine
loop with an integer step count, t = t0 + (k+1)*dt, instead of accumulating
`t_inner` (164-176).
Expected: `envelope/sine` RMS exactly 1.41421; `dc_offset` goes from -0.14% to
exact.

## Group 10: PSS DC offset (6 decks)

**Confirmed: `pss.zig:197` zeroing `i_prev` at every period start is the whole
offset.** The first trapezoid step of each period integrates i1/2 instead of
(i0+i1)/2, losing dt*i0/2 of charge per period. On the RC decks the steady
mean offset is -(i0*R)/(2N), with i0*R = 0 - v(0) = 0.15522 V:

| Deck | Predicted mean | Measured mean |
|---|---|---|
| `pss/rc_default` (N=256) | -3.03e-4 | -3.035e-4 |
| `pss/rc_minimal_grid` (N=32) | -2.43e-3 | -2.44e-3 |
| `pss/rc_slow_settling` | -3.11e-7 | -3.114e-7 |

A Python trapezoid-PSS model with the zeroed seam reproduces our waveforms to
5e-10 on the RC decks, 2.7e-9 on `bench_pss_rlc_driven`, 3.4e-4 on
`diode_clipper`. ngspice 44.2, trapezoid transient on `rc_default` at fixed
step T/256, settled 40 periods: -0.155213 / 0.0247023 at t = 0 / T/4; ours
-0.155393 / 0.0243274; the model with the fix -0.155216 / 0.0247021.
ngspice's mean is -1.3e-6. The charge seed `q_prev = q(x0)` (195-196) is
consistent; only `i_prev` is wrong.

Recipe, `pss.zig:194-198`: after `ckt.eval(x, 0)` (which leaves `rhs` = the
static residual f(x0, 0) and fills `c_vals`), replace the `simdZero(i_prev)`
with `i_prev[i] = -ckt.rhs[i]` where `ckt.c_vals[ckt.diag_slots[i]] != 0`,
else 0; skip row 0. A converged trapezoid step always leaves
`i_prev = -rhs(x_new)` (lines 147, 232), so this is exactly the periodic
trapezoid state carried across the seam; being a function of x0, it is inside
the finite-difference shooting Jacobian, so Newton stays quadratic. The mask
matters: on algebraic rows at a perturbed x0 an unmasked seed rings as
+-f(x0) undamped and makes the Jacobian near-singular. Rows whose charge has
no diagonal C entry fall back to today's behaviour; say so in a `ponytail:`
comment.

Rejected: backward Euler for the first step of each period (fails
`rc_minimal_grid` 3/9 at 3.17x, `rc_slow_settling` 9/9 at 1003x); carrying
`i_prev(T)` from the previous base integration (a Picard update contracting
at exp(-T/tau) per iteration, ~0.999 on `rc_slow_settling`).

Expected (model; worst error as a multiple of tolerance):

| Deck | Today | With fix |
|---|---|---|
| `rc_default` | 5/9, 3.91x | 0/9, 0.03x |
| `rc_negative_amplitude` | 5/9, 3.91x | 0/9, 0.03x |
| `rc_minimal_grid` | 3/9, 2.95x | 0/9, 0.14x |
| `rc_slow_settling` | 6/9, 6.52x | 0/9, 0.02x |
| `bench_pss_rlc_driven` | 10/65, 20.8x | 0/65, 0.10x |
| `diode_clipper` | 1/65, 2.09x | 0/65, 0.08x |

The same zeroing likely sits in the other `integrateOnePeriod` copies (pnoise,
the third PSS path); give them the same seed.

## Group 13: device DC physics (E6)

Each cause below was confirmed by a parameter experiment in BOTH simulators.

- **`dc/device_bsim1` (993x).** ngspice clamps K1 and K2 at 0
  (`b1temp.c:124-125`); the VA does not. K2 = -0.1 raises the VA's threshold
  by 0.1*PHI = 65 mV, the 150x subthreshold error at Vgs = 0.5. With K2 = 0 in
  both: 0/266 rows fail. Recipe: `models/bsim1.va:136-137`
  `k1e = max(k1 + ..., 0.0); k2e = max(k2 + ..., 0.0);`.
- **`dc/device_hisim2` (165x).** ngspice 44.2 forces HiSIM 2.80, whose LP
  (pocket length) defaults to 15e-9 when CODEP = 0 (`hsm2set.c:236`); the VA
  defaults LP to 0 (`hisim2_va.va:825`). LP = 15e-9 on the card: 0/262 fail;
  LP = 0 in both also matches. Recipe: LP default
  `(CODEP != 0 ? 0 : 15e-9)`. (MUECB0/MUECB1/MUESR1 defaults also differ,
  no effect on this deck.)
- **`dc/device_bsim2` (13.7x, only at Vgs = 0).** For Vgst <= Vglow,
  `b2eval.c:337-343` uses
  `Ids = Beta*Vtm^2*exp(Vof + Vgst/(n*Vtm))*(1 - exp(-Vds/Vtm))`, with no
  Uvert/U1/Kk/Aa; the VA sends weak inversion through the shared Vgeff
  expression, which divides by them. UA0 = UB0 = U10 = 0 in both: match.
  Recipe: add that closed-form branch for `vgst <= vgle` in `bsim2.va`
  (~461-510); apply `fclm` only when `vdsx > vdsat && ai0 != 0`.
- **`dc/device_bsim2_ngspice` (0.1-0.4% at Vbs = -3/-4 V).** `bsim2.va:479`
  clamps Vc with `max(..., 0)`; b2eval.c does not, and U1s is negative at
  those body biases. u1b = lu1b = 0: match. Recipe: drop the clamp, keep
  `1 + 2*vc > 0` as the sqrt guard.
- **`dc/device_mesa_output` (9x, 3 rows at the gate-current zero crossing).**
  The VA uses old constants kb = 1.3806226e-23, qe = 1.6021918e-19,
  phib = 8.010959e-20; ngspice 44 `const.h` has 1.38064852e-23 and
  1.6021766208e-19, PHIB default 0.5*CHARGE. Predicted gate-current shift
  -2.7e-4 relative (-5.5e-4 from Is, +2.8e-4 from vt), measured -2.7e-4;
  matching PHIB alone leaves the +2.8e-4 vt part, as predicted. Recipe:
  `mesa.va:48-49` ngspice 44 CODATA values, `:108` phib default
  8.010883104e-20; keep eps_gaas. `mesa.va` is owned by impl-va now: hand it
  over or land after. Re-check `dc/device_mesa_inverter` (row 48, 1e-3
  relative) and `tran/device_mesa_oscillator` (OP 17%) after it.
- **`dc/device_vdmos_output` (2x at 1e-11 A).** Off-state leakage is
  2e-12 A/V in espice, 1e-12 in ngspice. ngspice puts gmin only on the body
  diode (`vdmosload.c:808`); between d' and s' it uses m/RDS, or 1e-15 when
  RDS is absent (`vdmosset.c:292-299`). Recipe: `vdmos.va:281-282`, replace
  the `gmin*V(dp,sp)` term with `rds > 0 ? m*V/rds : 1e-15*V`.

Scratch decks and scripts: scratchpad `c/rA/` (`run.py`, `varyd.py`,
`grid.py`).


## Group 15: oracle defects (6 decks). USER DECISION, nothing changed

Each deck below fails against an oracle that is itself wrong or tests
something other than what the deck names. The harness cannot tell a model bug
from an oracle bug, so these stay red until the user picks an option.
Measured with the 4614f9a binary and ngspice 44.2.

**`tran/bench_tran_sffm_source`**: 251/253 rows fail (`i(v1)` worst 1.4e7x).
The deck's own header documents it: ngspice 44.2 emits a clean 10 kHz sine for
`SFFM(0 1 100k 2 10k)` (the modulating frequency as the carrier, no
modulation), while espice and VACASK both reproduce
`VO + VA*sin(2*pi*FC*t + MDI*sin(2*pi*FS*t))` to better than 1e-3. The oracle
is ngspice's output, so it pins ngspice's defect.
Options: (a) regenerate the oracle from the closed form (or VACASK) and keep
the deck as an SFFM test; (b) delete the deck; (c) keep it red as the
documented ngspice outlier. Recommended: (a).

**`dc/bench_mosfet_cmos_inverter`**: 1/101 fails, row 50 (vin = 2.5 V):
oracle 3.20557, ours 3.20234. The inverter is exactly balanced
(KP*W: 120u*10 = 60u*20, |VTO| equal, LAMBDA = 0), so at vin = VDD/2 every
vout in the both-saturated band satisfies KCL: the point is metastable and
each simulator reports where its Newton stopped. Measured at
reltol=1e-7 abstol=1e-15 vntol=1e-10: espice AND ngspice both give exactly
2.5, 220x off the oracle, so the oracle value is a loose-tolerance artefact.
Options: (a) drop row 50 from the oracle (the match is `exact`; switch to
`selected_rows` without 50); (b) break the symmetry in the deck (for example
LAMBDA=0.01 or a 1% KP mismatch) and regenerate from ngspice; (c) keep red.
Recommended: (b), the deck then still tests the transfer curve through the
switching point.

**`convergence/bench_ota_cutoff_abstol`**: all 10 columns fail (worst 733x).
The header says it outright: "CONVERGENCE-GATE STRESS, NOT AN ACCURACY
REFERENCE". Every branch current is 1.4x abstol, and ngspice misses KCL by
2.7x abstol, espice by 21x; asked to converge (abstol=1e-18 reltol=1e-10
vntol=1e-12) the two agree to 8.6e-11. The oracle is ngspice's stopping point
inside the tolerance.
Options: (a) regenerate the oracle at the tight options the header quotes and
add those `.options` to the deck, so it tests convergence to the true point;
(b) replace the value check with a convergence-only check (does the OP
converge at all); (c) delete. Recommended: (a).

**`dc/device_mesa_inverter`**: 1/101 row fails, row 48 (vin = 0.48 V, the
steepest point): `v(50)` 0.718074 vs 0.7188 (1.01x tol), `v(80)` 1.02x.
Not a tolerance artefact: at reltol=1e-7 abstol=1e-15 espice still gives
0.718074 and ngspice still matches the oracle. It is a 1e-3 relative model
difference in `mesa.va` at the highest-gain bias, so it belongs with group 13
(`device_mesa_output` is 9x off in the same model).
Options: (a) leave it red and fix it with the mesa DC work; (b) widen rtol to
2e-3 on this deck. Recommended: (a); the r-conformance "oracle defect" label
does not hold for this one.

**`sens/bench_sens_bridge`**: MissingColumn. 22 of the 24 oracle columns are
ngspice resistor parameters whose sensitivity is exactly 0 (`r5:rsh`,
`r5:wf`, `r4_temp`, `r3:kf`, `v(vin_phase)`, ...); the other two are
`v(r1_scale)` = -2.38631 and `v(r4:r)`. The deck tests ngspice's parameter
table, not the bridge: our `v(r1..r5)` match the ngspice reference to ~11
digits. Reaching the instance-spelled columns needs VerA instance parameters
(E10).
Options: (a) regenerate the oracle restricted to the physical columns
(`v(r1)`..`v(r5)`, `v(vin)`); (b) implement E10 (VerA + eval.zig) and the
missing resistor parameters; (c) keep red. Recommended: (a).

**`multi_analysis/bench_sens_diffpair`**: two defects stacked.
(1) Plot order: the deck has `.tf v(5) vcm` then `.tf v(5) vdm`; ngspice 44.2
writes the `vdm` plot FIRST, and the oracle keeps that reversed order. Both
plots are named `Transfer Function`, so ours (deck order) is compared against
the wrong one: -0.110341 vs -87.8474. Our numbers match ngspice's per
source: vcm -0.11034132 (ng -0.11034132), vdm -87.847339 (ng -87.847385).
(2) Sensitivity: the oracle samples 24 BJT/resistor parameter columns, most
ngspice FD noise or zero (`q3:tnom` -6.5e-14, `q3:kf` 7.95e-21,
`q3:ib_max` 7.95e-120, ...) plus two real mismatches: `v(q2:rb)` ours
1.3467e-3 vs ngspice 1.48794e-3, and `v(q4:ikf)` ours 9.34e-4 vs ngspice 0.
The ikf one is ngspice's FD at IKF = 0 ("infinite"), which perturbs nothing;
the rb one is consistent with ngspice perturbing RB without re-deriving RBM
(RBM defaults to RB at setup). Neither is evidence against our derivative.
Options: (a) reorder the two TF plots in the oracle to deck order (or make
the harness match same-named plots by their input column) and restrict the
sensitivity check to columns with a physical meaning, excluding `ikf` at 0
and FD noise below 1e-12; (b) emit TF plots in ngspice's order (reverse deck
order), which copies an ngspice quirk; (c) keep red. Recommended: (a).

