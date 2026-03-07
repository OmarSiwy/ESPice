* Unit fixture: N-JFET common-source bias point.
* Expected results: device_jfet.expected.json
* Origin: benchmark/fixtures/devices/jfet/circuit.sp
Vdd vdd 0 DC 12
Vg g 0 DC -1
Rd vdd d 2k
J1 d g 0 nj
.model nj NJF(vto=-2 beta=1m lambda=2m)
.op
.end
