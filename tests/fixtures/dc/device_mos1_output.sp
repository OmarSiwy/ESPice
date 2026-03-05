* NMOS Level 1 output characteristics: Ids vs Vds at multiple Vgs.
* Expected results: device_mos1_output.expected.json
* Origin: benchmark/fixtures/devices/mos1_output/circuit.sp
* Exercises cutoff, linear, and saturation regions.
Vds drain 0 DC 0
Vgs gate 0 DC 0
M1 drain gate 0 0 NMOS W=10u L=1u
.model NMOS NMOS(LEVEL=1 VTO=0.7 KP=120u GAMMA=0.4 PHI=0.65 LAMBDA=0.04 CBD=20f CBS=20f PB=0.8 MJ=0.5 CGSO=0.6n CGDO=0.6n)
.dc Vds 0 5 0.025 Vgs 0 5 0.5
.end
