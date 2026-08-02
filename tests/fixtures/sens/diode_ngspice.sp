* .sens of a diode divider against ngspice 45 (#71): column names follow
* cktsens.c, model parameters <card>:<param> (the diode has no principal
* parameter, so IS is v(d1:is)), instance parameters <card>_<param> with
* the multiplier as v(<card>_m), principal ones bare (v(r1), v(v1)).
* Left out: ISR (ngspice's sensitivity for a zero-valued parameter comes
* out 1e6 above the derivative) and IKF (NaN in ngspice); see
* dev/analysis/sensitivity.md.
V1 in 0 1
R1 in a 1k
D1 a 0 dm
.model dm D IS=1e-14 RS=10 N=1.2
.sens v(a)
.end
