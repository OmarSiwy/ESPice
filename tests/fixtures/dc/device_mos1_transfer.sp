* NMOS Level 1 transfer characteristics: Ids vs Vgs at fixed Vds.
* Expected results: device_mos1_transfer.expected.json
* Origin: benchmark/fixtures/devices/mos1_transfer/circuit.sp
* Tests threshold, subthreshold, and strong inversion.
Vds drain 0 DC 3
Vgs gate 0 DC 0
M1 drain gate 0 0 NMOS W=10u L=1u
.model NMOS NMOS(LEVEL=1 VTO=0.7 KP=120u GAMMA=0.4 PHI=0.65 LAMBDA=0.04)
.dc Vgs 0 5 0.01
.end
