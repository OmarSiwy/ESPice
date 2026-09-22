* Half-wave rectifier with smoothing capacitor and load.
* Expected results: bench_power_rectifier.expected.json
* Origin: benchmark/fixtures/power/rectifier/circuit.sp
Vac in 0 DC 0 SIN(0 10 1k)
D1 in out DR
C1 out 0 47u
Rload out 0 1k
.model DR D(IS=1e-12 N=1)
* tmax pinned at 1u deliberately. The diode has no RS and the source no series
* impedance, so i(vac) is a raw exponential of a node voltage: dI/I = dV/Vt =
* 38.7*dV. At the default grid (tmax = tstop/50 = 100u) BOTH engines satisfy the
* same Shockley equation to 6 digits at their OWN bias -- ngspice I=3.1407105 vs
* raw 3.1407293 at Vd=0.7442754, espice I=2.9998799 vs raw 2.9998720 at
* Vd=0.7430888 -- and the 1.19 mV integration difference exponentiates to 4.69%,
* which was the whole reported error. Converged (tmax=20n, both engines agree to
* 7 figures) the peak is -2.9397110 @ t=1.527200e-5; ngspice's coarse answer is
* +6.84% (trapezoidal LTE overshoot) and espice's is +2.05%, i.e. the fixture was
* scoring espice against the reference's own discretization error. tmax=1u costs
* 5005 points and lands the pair at max 9.53e-5 / rms 7.41e-6.
.tran 10u 5m 0 1u
.end
