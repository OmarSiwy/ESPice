* BJT reverse_active
* Expected results: bjt_reverse_active.expected.json
Vb b 0 0.8
Vc supply 0 0
Rc supply c 1k
Q1 c b 0 qm
.model qm NPN(is=1e-15 bf=100 br=2 vaf=100)
.op
.options reltol=1e-6 abstol=1e-12 vntol=1e-8 method=gear temp=27 tnom=27
.end
