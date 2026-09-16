* RC discharge, gear, tau=1e-06s
* Expected results: rc_discharge_gear_1e-06.expected.json
Vin in 0 0
R1 in out 1k
C1 out 0 9.999999999999999e-10
.ic v(out)=1
.tran 9.999999999999999e-10 5e-06 0 9.999999999999999e-10 uic
.options reltol=1e-6 vntol=1e-9 abstol=1e-14 method=gear
.end
