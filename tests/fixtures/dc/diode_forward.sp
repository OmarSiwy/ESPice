* diode forward
* Expected results: diode_forward.expected.json
Vin in 0 0
R1 in out 1k
D1 out 0 dm
.model dm D(is=1e-14)
.dc Vin 0 1 0.1
.options reltol=1e-7 abstol=1e-14 vntol=1e-9
.end
