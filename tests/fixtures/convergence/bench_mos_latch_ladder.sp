* Cross-coupled NMOS cell whose DC sweep drops out of plain Newton into the
* Expected results: bench_mos_latch_ladder.expected.json
* Origin: benchmark/fixtures/convergence/mos_latch_ladder/circuit.sp
* gmin rung -- the ONE thing the convergence corpus could not see.
*
* Everything else here passes or fails on the ANSWER. This deck is scored on
* the PATH: a Jacobian perturbation that leaves the answer inside reltol can
* still flip `plain Newton converged` to `plain Newton failed`, and then the
* whole gmin/source ladder is paid at every operating point that flipped.
* That tax is invisible to every other fixture in the tree.
*
* Why plain Newton is hard here, and why nothing smaller reproduces it:
*
*   - bl/blb and q/qb have NO resistive path to a rail. Every conductance on
*     them comes from a LEVEL=1 MOSFET, and LEVEL=1 has no subthreshold
*     region: below Vt the row is exactly zero, above it the square law. The
*     four diode-connected loads (w=5u) sit on the wrong side of that kink.
*   - GAMMA=1.83 puts the body effect in the feedback path: each load is a
*     source follower whose own Vt moves with the node being solved for, so
*     the kink chases the iterate instead of standing still.
*   - mq/mqb are a latch. Two basins, and the Newton path between them is not
*     a descent -- |F| falls to 1e-5 A while dx is still volts, iterate after
*     iterate, all refused by the `delta` gate (ZP_NEWTON_DEBUG shows it).
*     Plain Newton needs ~50 of its ITL1=100 iterations to land.
*
* Half-budget is the point. The margin is one Jacobian perturbation wide.
*
* Reduction evidence (docs/perf/ladder-deck-2026-09-10.md): deleting ANY of
* these ten devices, or swapping any pair of them for resistors, drops plain
* Newton to ~20 iterations and the discrimination vanishes. Seven purpose-built
* smaller latches (6- and 8-device) were measured and none reproduced it.
*
* MEASURED, `ZP_OPDBG=1 ... | grep -c "plain conv=true"`:
*
*              ladder entries   plain converged   gmin rungs   Newton iterates
*   f64                     3                 3            0               360
*   -Djac-f32=mos1          3                 1           22               547
*
* Same three cold restarts, same answer (max 1.1 mV of 5 V, inside reltol),
* +52% Newton work. Holds over lambda 0.05..0.15, gamma 1.4..2.0 and sweep
* step 0.05..0.5 -- it is a region, not a knife edge.
*
* What breaks it: an f32 Jacobian, a narrowed Dual width, a cheaper limiter,
* any reordering that changes the pivot sequence. All of them keep the answer
* and move the count.
*
* Distilled from benchmark/fixtures/ngspice/mosmem (12 devices, three PULSE
* sources, tran). The PULSE drive is not load-bearing: DC-biasing the gates at
* their t=0 values reproduces mosmem's 50-vs-100 plain-iteration split exactly.
vdd  vdd 0 dc 5
vwl  wl  0 dc 2
vd   d   0 dc 0
vdb  db  0 dc 2
mwr  bl  d   0 0 mod w=250u l=5u
mwrb blb db  0 0 mod w=250u l=5u
mlbl vdd vdd bl  0 mod w=5u   l=5u
mlbb vdd vdd blb 0 mod w=5u   l=5u
mpg  q   wl  bl  0 mod w=50u  l=5u
mpgb qb  wl  blb 0 mod w=50u  l=5u
mq   q   qb  0 0 mod w=250u l=5u
mqb  qb  q   0 0 mod w=250u l=5u
mlq  vdd vdd q  0 mod w=5u   l=5u
mlqb vdd vdd qb 0 mod w=5u   l=5u
.model mod nmos(level=1 vto=0.5 phi=0.7 kp=1.0e-6 gamma=1.83 lambda=0.115)
.dc vd 0 5 0.1
.end
