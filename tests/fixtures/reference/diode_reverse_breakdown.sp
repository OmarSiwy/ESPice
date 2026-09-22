* Diode reverse_breakdown
* Expected results: diode_reverse_breakdown.expected.json
Vin in 0 -10
R1 in out 100
D1 out 0 dm
.model dm D(is=1e-14 bv=5.1 ibv=1m)
.op
.options reltol=1e-6 abstol=1e-12 vntol=1e-8 method=gear temp=27 tnom=27
.end
