* MESA transistor DC operating point.
* Expected results: device_mesa.expected.json
* Origin: benchmark/fixtures/devices/mesa/circuit.sp
* ngspice: Z device with NMF model type, level=2 or 3.
Vdd vdd 0 DC 5
Vg g 0 DC -0.3
Rd vdd d 500
Z1 d g 0 nmesa
.model nmesa NMF(LEVEL=2 VTO=-1.5 BETA=2m ALPHA=2 LAMBDA=5m RD=10 RS=10)
.op
.end
