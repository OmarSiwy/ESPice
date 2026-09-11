* HICUM/L2 common emitter with RBX = RE = RCX = 0 (all three branches
* collapsed) and tnode grounded, against ngspice 45 (#160). The disabled
* thermal branch leaves a void unknown; the dense AC path (n <= 16) gives
* it a unit pivot as the sparse LU does, instead of reporting Singular.
* Oracle: ngspice 45's DC central difference of v(d) over V1 = 0.8 +- 1e-4
* at reltol=1e-9 (-104.32655). ngspice's own .ac gives -102.174, 2% off its
* DC slope (its HICUM small-signal stamp), so its AC is not the oracle.
.model qm NPN(LEVEL=8 C10=2e-30 QP0=2e-14)
VDD vdd 0 3
V1 g 0 DC 0.8 AC 1
RD vdd d 1k
Q1 d g 0 0 qm
.ac lin 1 1k 1k
.end
