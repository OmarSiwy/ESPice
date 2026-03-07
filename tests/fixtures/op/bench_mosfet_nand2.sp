* Two-input CMOS NAND gate, DC operating point with both inputs high.
* Expected results: bench_mosfet_nand2.expected.json
* Origin: benchmark/fixtures/mosfet/nand2/circuit.sp
VDD vdd 0 DC 5
VA a 0 DC 5
VB b 0 DC 5
M1 out a n1 0 NMOS L=1u W=10u
M2 n1 b 0 0 NMOS L=1u W=10u
M3 out a vdd vdd PMOS L=1u W=20u
M4 out b vdd vdd PMOS L=1u W=20u
.model NMOS NMOS(LEVEL=1 VTO=0.7 KP=120u)
.model PMOS PMOS(LEVEL=1 VTO=-0.7 KP=60u)
.op
.end
