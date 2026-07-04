* Promote fixture: dense DC sweep — 2001 solves of one small structure.
Vin in 0 DC 0
R1 in out 1k
D1 out 0 dm
.model dm D(is=1e-14)
.dc Vin 0 2 0.001
.end
