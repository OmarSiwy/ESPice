* BSIM3SOI-PD output characteristics: Ids vs Vds at multiple Vgs.
* Expected results: device_b3soipd_output.expected.json
* Origin: benchmark/fixtures/devices/b3soipd_output/circuit.sp
* Tests partial depletion SOI floating body effects.
Vds drain 0 DC 0
Vgs gate 0 DC 0
Vbs body 0 DC 0
M1 drain gate 0 body nsoipd W=10u L=0.18u
.model nsoipd NMOS(LEVEL=10 VERSION=2 TNOM=27 TOX=4.1e-9 VTH0=0.35 K1=0.53 K2=-0.06 VSAT=1.5e5 U0=280 RDSW=200)
.dc Vds 0 1.8 0.01 Vgs 0 1.8 0.3
.end
