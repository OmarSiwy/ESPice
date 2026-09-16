* Unit fixture: BSIM4 NMOS bias point (level 54, default params).
* Expected results: device_bsim4.expected.json
* Origin: benchmark/fixtures/devices/bsim4/circuit.sp
Vdd vdd 0 DC 1.1
Vg g 0 DC 0.7
Rd vdd d 10k
M1 d g 0 0 n4 W=1u L=0.1u
.model n4 NMOS(level=54)
.op
.end
