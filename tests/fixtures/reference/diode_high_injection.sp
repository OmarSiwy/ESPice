* Diode high_injection
* Expected results: diode_high_injection.expected.json
Vin in 0 5
R1 in out 100
D1 out 0 dm
.model dm D(is=1e-14 ikf=.01)
.op
.options reltol=1e-6 abstol=1e-12 vntol=1e-8 method=gear temp=27 tnom=27
.end
