# Device models

The built-in devices are Verilog-A sources in `models/`. VerA compiles each
one at build time into a host object (and a GPU kernel when the model is
eligible) behind the neutral device ABI in `src/device/abi.zig`. The SPICE
letter and LEVEL policy that picks a model for a card is
`src/frontend/spice.zig`; card binding is `src/frontend/builder.zig` and
`src/device/bind.zig`.

The native transmission lines (LTRA, TXL, CPL) are the exception: they are
Zig devices in `models/native/` built through the same evaluator. Their
Verilog-A ports sit beside them and are not built; see
[native-transmission-line-migration.md](../native-transmission-line-migration.md)
and [vera-gaps.md](../vera-gaps.md).

## Attribution and licenses

Every source header carries one of three attribution forms:

- **own**: "Verilog-A implementation: Omar El-Sawy, University of Waterloo"
  only.
- **derived**: that line, plus "Based on: ngspice ..." naming the original
  model and its originator, plus the ngspice notice (Regents of the
  University of California and others, modified BSD).
- **third-party**: the original notices and body untouched, plus one note
  naming the ESPice flattening and adaptation by Omar El-Sawy.

| Models | Attribution |
|---|---|
| capacitor, inductor | own |
| resistor, vcvs, vccs, cccs, ccvs, kinduc, cswitch, vswitch, bsource, vsource, isource | derived |
| tline, lossy_tline, coupled_tlines, diode, jfet, jfet2, mes, mesa, gummel_poon | derived |
| mos1, mos2, mos3, mos6, mos9, bsim1, bsim2, bsim3 | derived |
| hfet1, hfet2, vdmos | derived |
| bsim4va, bsimsoi_va, hisim2_va, hisimhv_va, hicumL2_va, vbic13_4t, psp103 | third-party |

**`bsim4va.va` is Cogenda's VA-BSIM48 under CC-BY-NC 4.0, a non-commercial
license.** Check it before any commercial use of ESPice.

`psp103.va` is PSP 103.7 (NXP Semiconductors, CEA-Leti, Delft University of
Technology) as ngspice-45 ships it, under the Si2 CMC in-code statement
reproduced in its header. That license forbids charging for the model code
itself, and any product built on it must credit NXP Semiconductors, Delft
University of Technology and CEA in its documentation; this paragraph is that
credit. The only edits are the module name, the escaped `\nmos`/`\pmos`
parameter identifiers (Annex B keywords VerA rightly refuses as plain names)
and the `NQSmodel` define (below).
It has no `$limit`, so Newton runs it unlimited. The MOSFET LEVEL is 1040,
since ngspice-45 has no PSP LEVEL.

Measured against VACASK on `stress/vacask_ring`, the model agrees and the
time grids do not. VACASK running this same file (compiled by its OpenVAF-r)
and espice both converge on a 3.4393 ns ring period: at reltol=1e-6 they sit
2.6e-5 apart (3.439325 vs 3.439414 ns). At the deck's own options the periods
are 3.452040 ns (VACASK, PSP 103.7), 3.452546 ns (VACASK's PSP 103.4 OSDI,
the oracle) and 3.454436 ns (espice), so the 6.9e-4 gap is the two
simulators' timestep control, not the device. Converged, the two model
versions differ by 7e-6 (VACASK/103.4 3.439302 ns). Samples of the free-running
ring match only on VACASK's exact grid (VACASK itself scores 1.75e4x with the
103.7 OSDI), so the deck checks the measured period and swing of v(1)
(the harness `oscillation` check, rtol 7e-3 and 1e-2) plus samples up to
1.25 ns; the tolerance rationale is in the oracle's notes.

The NQS model ships on (user decision). `PSP103_nqs_macrodefs.include` sits
after `` `define OPderiv `` under `` `ifdef NQSmodel ``, where upstream's
`psp103_nqs.va` includes it, and `` `define NQSmodel true `` is set, so
every PSP instance carries 48 unknowns instead of 12: nine NQS nodes, nine
of VerA's host-integrated `idt$k` and their 18 branch flows. None of them
collapse at SWNQS=0, because SWNQS is a card parameter. Cards still default
to SWNQS=0, the quasi-static model.

Checked against VACASK, which ran the same PSP 103.7 sources compiled by
OpenVAF-r as `PSPNQS103VA`, on a 10u/10u nMOS at Vd = 1.2 V with the gate
stepped 0 to 1.2 V in 50 ps, over 4 ns, gear2 on both sides. With SWNQS=1,
from 50 ps after the edge to the end, drain and gate currents agree within
2.9e-7 and 5.8e-7 A (about 0.1% of the 2.4e-4 A final drain current). The
NQS effect itself (SWNQS=1 minus SWNQS=0) is 9.011e-3 A in espice against
9.015e-3 A in VACASK.

Cost at SWNQS=0, measured against the QS build (main daa50f3). Callgrind
instructions: `stress/vacask_ring` cut to 50 ns (18 instances, 1107 vs 1113
steps) goes 0.84e9 -> 2.32e9 (2.8x). The post-layout `ring_psp103_1k` deck
from `tests/benchmark/postlayout/gen.py`, cut to 200 ps (960 instances, 114
steps both), goes 9.44e9 -> 19.7e9 (2.1x). Charge states double (vacask_ring
n_qt 162 -> 324). Wall time on a loaded host (load average 160-300), best of
three: vacask_ring 6.0 -> 11.1 s, ring_psp103_1k 18.7 -> 57.3 s,
chain_psp103_1k 10.8 -> 26.5 s. The CUDA image grows from 7.8 MB to 34 MB
of PTX, larger than hisimhv_va's, so the cold-JIT figure in build.zig's
`gpu_max_model_bytes` table no longer holds for psp103. It was not
re-measured.

Output at SWNQS=0: the extra unknowns change the matrix, so results match
the QS build to roundoff but not bitwise. `chain`/`ring` post-layout decks
at 200 ps keep the same time grid, with at most 4.9e-13 V difference. The
`stress/vacask_ring` operating point moves 8.7e-12 V. The free-running ring
grows that by about 10x per 300 ps until the time grid splits at 2.2 ns
(20741 -> 20370 accepted points over 1 us). Its checked period and swing
move 0.2564x -> 0.2565x of tolerance.

These originator attributions were written from memory and still need a
check against the original sources: T. Ytterdal (hfet1, hfet2), Holger Vogt
and Dietmar Warning (vdmos body diode), T. Quarles and A. Gillespie (mos9),
Colin McAndrew et al. (VBIC).

## Source conventions

- **Parameter declaration order is part of the model's behavior.** It is the
  parameter list that `.mc` and `.sens` walk, so it sets the Monte Carlo draw
  order. Reordering parameters changes `.mc` results.
- **mos1 is the reference layout of the MOS family.** mos2, mos3, mos6,
  mos9, bsim1, bsim2 and bsim3 follow its section order and local names,
  use internal nodes `di`/`si`, and spell the polarity parameter `type`
  (+1 NMOS, -1 PMOS).
- bsim2 keeps its original contribution order. Moving it to the family's
  canonical order changed its DC sweeps by 1 ulp.
- The remaining differences inside the MOS family are real differences in
  the arithmetic, kept on purpose because each follows its ngspice model:
  the junction depletion charge arrangement (mos1 `jchg`, the mos2/mos3/mos9
  `qdep` variants, mos6), the reverse-bias junction current (flat in mos1,
  cubic in mos3/mos9), Meyer halves against full-and-average, and the form
  of KP(T).
- The Meyer gate charges of mos1/2/3/6/9 follow ngspice's first Newton
  iteration of each transient step. On a MODEINITPRED iteration, ngspice
  extrapolates the charge from the last two accepted points, which with
  the host's linear predictor is the increment since the last accept times
  that accept's capacitance, while `geq` keeps the present one. On the
  first step's MODEINITTRAN iteration, the caps stamp nothing. A step that
  converges in two iterations publishes that first solve, so this shows in
  the output. Each cap carries a second `ddt()` site with a zero Jacobian
  that holds the difference. Against main 6d0b951: `tran/device_mos6_inverter`
  goes 41.4x -> 0.105x (with `vera_nodiff` on mos6's caps, as on the others),
  `tran/bench_tline_txl1_1_line` 5.41x -> 0.0017x,
  `tran/bench_ngspice_mosmem` 0.073x -> 0.0002x. `tran/bench_ngspice_mosamp`
  now tracks ngspice's grid to 1.31 ns instead of 1.15 ns.
- Sharing the MOS junction helpers through an `include` would need build.zig
  to track the included file as a VerA input. Not done.
- A model of at least 20 KB (`heavy_model_bytes` in build.zig) is scheduled
  as a heavy GPU compile. This affects build scheduling only.

`setPolarity` in `src/frontend/builder.zig` still has branches for the old
polarity spellings `dev_type`, `mtype` and `typeZ5f` (the escaped `type_`).
No model in `models/` declares them any more, so those branches are
comptime-false. The jfet, jfet2, mes, mesa and vdmos models have no polarity
parameter, so a P-type model card on them fails with `UnsupportedDevice`
instead of running N-type.

## Conformance fixes against ngspice

Each fix below matches the model to ngspice 44.2. The cause, the ngspice
reference and the landing commit are in
[conformance-phase2.md](../conformance-phase2.md) (groups 5, 13 and 15);
current deck status is in `issues.md`.

| Model | Behavior now | ngspice reference |
|---|---|---|
| vbic13_4t | A card with fewer than five nodes gets `sw_et = 0` (self-heating off) unless the card sets `SW_ET`; set in `addSingleDevice` | inp2q.c:85-87 ties the missing thermal node to ground |
| vbic13_4t | With TD > 0, `i(q1)` is published as the xf2 node voltage (the excess-phase branch carries only a 1 ohm load) | vbicsetup.c:510-525 |
| vbic13_4t | Shot and flicker noise are not scaled by `MFACTOR_USE` a second time, so noise scales as M, not M^2 | vbicnoise.c |
| bsim1 | K1 and K2 are clamped at 0 | b1temp.c:124-125 |
| hisim2_va | LP defaults to 15 nm when CODEP = 0 (HiSIM 2.80, which ngspice 44.2 forces) | hsm2set.c:236 |
| bsim2 | Vc is not clamped at 0; only the sqrt argument is guarded | b2eval.c |
| mesa | CODATA constants of ngspice 44 `const.h`; PHIB default 0.5 * CHARGE | const.h, mesasetup.c:126 |
| mos1 | ngspice's `const.h` k and q (CODATA 2014) and vt = T * (k/q); gmbs = gm * gamma / (2 * sarg) also above vbs = 0, where AD of the Taylor-continued root would give gamma / (2 * sqrt(phi)) | const.h, main.c:501, mos1load.c:478-491 |
| vbic13_4t | DEVpnjlim on the six junctions at the ambient vt, vcrit from IS * M; without it plain Newton swung internal nodes by kV and never converged on `multi_analysis/device_vbic_ce_amp` | vbicload.c:655-667, vbictemp.c:84 |
| vdmos | d'-s' leakage is m/RDS, or 1e-15 S without RDS; gmin goes on the body diode only | vdmosset.c:292-299, vdmosload.c:808 |
| vsource, isource | SFFM reads (VO VA FM MDI FC TD PHASEM PHASEC) and limits MDI to FC/FM | vsrcload.c:228-282, isrcload.c:206-254 |
| bsim4va | CVCHARGEMOD defaults to 0 (upstream VA had 1), so capMod 1/2 take VgsteffCV from NOFF and VOFFCV as the BSIM4.8 manual specifies. With 1, sky130 nfet Cgg ran 3.9% low at 1 MHz and inverter tpd_hl 1.8% fast; now within 3e-6 and 0.12% (`ac/device_bsim4_capmod2`) | b4set.c:102-103, b4ld.c:3351 |
| bsim4va | GIDLMOD defaults to 0 (upstream VA had 1), selecting the pre-4.7 GIDL/GISL formulation as the BSIM4.8 manual and ngspice do | b4set.c:458-459 |

Known open differences: VBIC puts the RBP thermal noise on bp-cx where
ngspice puts it between emitEI and emit (0.9% at 100 MHz), and the VBIC
physical constants differ from ngspice's (about 1e-6 relative at one zero
crossing). Both are described under group 5.

Intentional divergences, kept rather than matched:

- `bsource`: a constant integer exponent (`powi`) keeps the sign of its base
  through repeated multiplication, matching ngspice's hspice/ltspice compat
  mode (ptfuncs.c `PTpowerH`) and the fixture oracles' analytic math;
  ngspice's default mode computes `|x|^k` for every constant power (see
  `models/native/bsource.zig`).
- `vbic13_4t` keeps VBIC 1.3's `avalm` smoothing, which shifts the smooth
  max by `vminm` (lines ~753-757); `dc/device_vbic_forced_output`'s ngspice
  44.2 oracle runs VBIC 1.2 (vbicload.c:3597), which has no such shift.
- `noise/device_vbic_noise_scale`: ngspice's own noise density total omits
  the RS and ICCP contributions that its integrated totals include
  (vbicnoise.c:167-177); espice keeps them in both.

## Physical constants

A model uses the constants its ngspice device uses, spelled as literals
(VerA preloads `constants.vams`, whose `P_K`/`P_Q` are the NIST 1998 set, not
ngspice's):

- const.h (CODATA 2014) k = 1.38064852e-23, q = 1.6021766208e-19, with
  vt = (k/q) * T as `CONSTKoverQ * T` and `CONSTvt0` = k * 300.15 / q:
  diode, jfet, jfet2, mes, mesa, vdmos, hfet1, hfet2, gummel_poon,
  resistor noise, mos1, mos2, mos3, mos6, mos9 (with eps0 =
  8.854214871e-12, mos*temp.c); bsim1 (CONSTvt0 throughout); bsim2
  junctions (CONSTvt0; the channel keeps b2temp.c's own 8.625e-5); hicumL2
  (CONSTKoverQ in temp, k*T/q in load); vbic13_4t pnjlim vt and noise; bsim4va and bsimsoi_va noise, plus
  bsim4va's two CHARGE sites (b4temp.c:2294, b4ld.c:5412).
- The model's own values, which ngspice copies: BSIM3/3SOI/4/4SOI `KboQ`,
  `Charge_q`, `EPS0`, `EPSSI`; VBIC's `KB_VBIC`/`QQ_VBIC` in its thermal
  voltage; HiSIM's `C_QE`/`C_KB`; PSP's `KBOL`/`QELE`. HiSIM2 (3.2.0 here,
  2.8.0 in ngspice) and HiSIM-HV (2.51 here, 2.20 in ngspice) are a MODEL
  VERSION DIFFERENCE with the same constants.

`gummel_poon` switched last: its `.disto` third harmonic was roundoff
until the third-order kernel got its own step (see
[distortion](../analysis/distortion.md)).

## Nominal temperature

`.options tnom` reaches a built-in model through VerA's reserved Model field
`nom_temp__`, which `deriveModel` in `src/frontend/builder.zig` writes just
before `derive`. A card TNOM or TREF still wins through `__given`.

Known limitation: devices loaded at runtime from `.hdl` sources
(`NetBuilder.addDynDevices`) bind their cards and call `derive` without
writing `nom_temp__`, so they always see the default tnom of 27 degC.
