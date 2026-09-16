* BSIM4SOI output characteristics: Ids vs Vds at multiple Vgs.
* Expected results: device_b4soi_output.expected.json
* Origin: benchmark/fixtures/devices/b4soi_output/circuit.sp
* Tests BSIM4 SOI physics: self-heating, body effects.
Vds drain 0 DC 0
Vgs gate 0 DC 0
Vbs body 0 DC 0
M1 drain gate 0 body nb4soi W=1u L=0.1u
.model nb4soi NMOS(LEVEL=58 VERSION=4.4 TNOM=27  TOXP=1.5e-9 VTH0=0.3 K1=0.5 K2=-0.1 VSAT=1.5e5 U0=300 RDSW=200)
.dc Vds 0 1.1 0.01 Vgs 0 1.1 0.2
.end
