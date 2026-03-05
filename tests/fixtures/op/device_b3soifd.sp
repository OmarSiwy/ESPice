* BSIM3SOI-FD (Full Depletion) NMOS operating point.
* KNOWN GAP: the BSIM3SOI FD/DD model families are absent from the current device catalog.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: device_b3soifd.expected.json
* Origin: benchmark/fixtures/devices/b3soifd/circuit.sp
* ngspice: NMOS level=55, 4 terminals (D G S E).
Vdd vdd 0 DC 1.8
Vg g 0 DC 1.0
Vb body 0 DC 0
Rd vdd d 10k
M1 d g 0 body nsoifd W=10u L=0.18u
.model nsoifd NMOS(LEVEL=55 VERSION=2 TNOM=27 TOX=4.1e-9 VTH0=0.35 K1=0.53 K2=-0.06 KB1=1 VSAT=1.5e5 U0=280 RDSW=200)
.op
.end
