* RC discharge, euler, tau=0.001s
* Expected results: rc_discharge_euler_0p001.expected.json
Vin in 0 0
R1 in out 1k
C1 out 0 1e-06
.ic v(out)=1
.tran 1e-06 0.005 0 1e-06 uic
.options reltol=1e-6 vntol=1e-9 abstol=1e-14 method=gear maxord=1
.end
