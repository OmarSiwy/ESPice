* HICUM/L2 common emitter with RBX = RE = RCX = 0 (all three branches
* collapsed) and tnode grounded (#160). The disabled thermal branch leaves
* a void unknown; the dense AC path (n <= 16) gives it a unit pivot as the
* sparse LU does, instead of reporting Singular.
* Oracle: VACASK running the same upstream HICUM/L2 v3.2.0 source
* (hicumL2_v320.va, compiled by OpenVAF-r) with tnode tied to ground.
* ngspice 45 implements HICUM/L2 2.4.0, whose operating point here sits
* 0.8% away, so it is not the oracle for this deck.
.model qm NPN(LEVEL=8 C10=2e-30 QP0=2e-14)
VDD vdd 0 3
V1 g 0 DC 0.8 AC 1
RD vdd d 1k
Q1 d g 0 0 qm
.ac lin 1 1k 1k
.end
