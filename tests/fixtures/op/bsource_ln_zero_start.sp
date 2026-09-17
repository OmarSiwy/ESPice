* B source ln() of a node that starts Newton at 0 V (#77): ngspice's PTlog
* returns -1e99 at 0, so Newton recovers; v(o) = ln(2.5) = 0.916291.
* ngspice-45: o = 9.162907e-01.
V1 x 0 2.5
B1 o 0 V=ln(v(x))
R1 o 0 1k
.op
.end
