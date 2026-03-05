* diode bad nodeset positive
* Expected results: diode_bad_nodeset_positive.expected.json
Vin in 0 5
R1 in out 1000
D1 out 0 dm
.model dm D(is=1e-14 n=1)
.nodeset v(out)=100
.op
.options temp=27 tnom=27 reltol=1e-6 abstol=1e-14 vntol=1e-8
.end
