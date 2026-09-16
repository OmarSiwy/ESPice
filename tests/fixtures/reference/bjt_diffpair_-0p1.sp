* Differential pair current steering and symmetry
* Expected results: bjt_diffpair_-0p1.expected.json
Vcc vcc 0 5
Vp bp 0 -0.05
Vn bn 0 0.05
Itail emit neg 1m
Vneg neg 0 -5
R1 vcc op 2k
R2 vcc on 2k
Q1 op bp emit qm
Q2 on bn emit qm
.model qm NPN(is=1e-15 bf=200 vaf=100)
.op
.options reltol=1e-6 abstol=1e-12 vntol=1e-8 method=gear temp=27 tnom=27
.end
