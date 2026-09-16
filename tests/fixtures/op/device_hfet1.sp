* HFET1 (heterojunction FET level 1) DC operating point.
* Expected results: device_hfet1.expected.json
* Origin: benchmark/fixtures/devices/hfet1/circuit.sp
* ngspice: Z device with NHFET model type.
Vdd vdd 0 DC 3
Vg g 0 DC 0
Rd vdd d 500
Z1 d g 0 nhf1
.model nhf1 NHFET(LEVEL=5 VTO=0.15 LAMBDA=0.15 MU=0.4 DI=4e-8 DELTA=3 VS=1.5e5 ETA=1.28 M=3 SIGMA0=0.057)
.op
.end
