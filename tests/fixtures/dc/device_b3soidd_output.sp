* BSIM3SOI-DD output characteristics: Ids vs Vds at multiple Vgs.
* KNOWN GAP: the BSIM3SOI FD/DD model families are absent from the current device catalog.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: device_b3soidd_output.expected.json
* Origin: benchmark/fixtures/devices/b3soidd_output/circuit.sp
* Tests dynamic depletion SOI self-consistent body potential.
Vds drain 0 DC 0
Vgs gate 0 DC 0
Vbs body 0 DC 0
M1 drain gate 0 body nsoidd W=10u L=0.18u
.model nsoidd NMOS(LEVEL=56 VERSION=2 TNOM=27 TOX=4.1e-9 VTH0=0.35 K1=0.53 K2=-0.06 KB1=1 VSAT=1.5e5 U0=280 RDSW=200)
.dc Vds 0 1.8 0.01 Vgs 0 1.8 0.3
.end
