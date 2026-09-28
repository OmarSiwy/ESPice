* .nodeset holds nodes at a guess for the operating point's first solve
* (ngspice CKTnodeset, MODEINITJCT/INITFIX), which picks a latch's state;
* ignoring it settled on the symmetric metastable point. Oracle: ngspice 45.
* Expected results: nodeset_latch.expected.json
vcc vcc 0 5
rc1 vcc q 1k
rc2 vcc qb 1k
rb1 qb b1 10k
rb2 q b2 10k
q1 q b1 0 qmod
q2 qb b2 0 qmod
.model qmod npn(bf=100 is=1e-16)
.nodeset v(q)=5 v(qb)=0
.op
.end
