* HSPICE `SWEEP MONTE=` on a transient with Latin hypercube sampling: the
* nominal run, one plot per trial, and .meas statistics over the trials.
* R draws from a .param agauss, C from a .variation element row.
* Oracle: analytic. The step response crosses 0.5 V at t = R C ln 2:
* 693.1 ns nominal; over trials the mean is 693.1 ns and the relative sigma
* sqrt(0.03^2 + 0.1^2) = 10.4 %, 72.4 ns.
* Expected results: monte_tran_meas.expected.json
.param rv=agauss(1k, 30, 1)
v1 in 0 pwl(0 0 1p 1)
r1 in out rv
c1 out 0 1n
.variation
.local_variation
.element_variation
c c=10 %
.end_element_variation
.end_local_variation
.end_variation
.option seed=3 sampling_method=lhs
.tran 10n 3u sweep monte=200
.meas tran tc when v(out)=0.5 rise=1
.end
