* HSPICE .lin with a mixed-mode P element [SA Ch.17]: port 1 is balanced
* (legs a and b against ground, z0 = 50), port 2 single-ended at c. An
* asymmetric resistive network with 1 nF at c couples every mode, so the
* modes, in HSPICE's Touchstone order d1, s2, c1, all convert.
* Oracle: analytic (see the expected.json derivation).
* Expected results: lin_mixed_mode.expected.json
P1 a b 0 port=1 z0=50
P2 c 0 port=2 z0=50
RA a 0 100
RB b 0 200
RAB a b 300
RAC a c 50
RC c 0 75
RBC b c 400
C1 c 0 1n
.ac lin 1 1meg 1meg
.lin
.end
