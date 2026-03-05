* RC discharge, gear, tau=1s
* Expected results: rc_discharge_gear_1.expected.json
Vin in 0 0
R1 in out 1k
C1 out 0 0.001
.ic v(out)=1
.tran 0.001 5 0 0.001 uic
.options reltol=1e-6 vntol=1e-9 abstol=1e-14 method=gear
.end
