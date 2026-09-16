* .step of a parameter a .model value reads (#65): the diode's IS follows
* the step, so the 1 V reverse current is -(IS + gmin*1V) per point.
* Oracle: ngspice-45 run once per point with .param isat=<value>.
.param isat=1e-14
V1 0 a 1
D1 a 0 dm
.model dm d is={isat}
.step param isat list 1e-14 2e-14
.op
.end
