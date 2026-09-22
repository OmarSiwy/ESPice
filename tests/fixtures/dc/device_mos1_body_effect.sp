* NMOS Level 1 body effect: Vth shift with substrate bias.
* Expected results: device_mos1_body_effect.expected.json
* Origin: benchmark/fixtures/devices/mos1_body_effect/circuit.sp
* Sweeps Vgs at multiple Vbs values to show threshold shift.
Vds drain 0 DC 3
Vgs gate 0 DC 0
Vbs bulk 0 DC 0
M1 drain gate 0 bulk NMOS W=10u L=1u
.model NMOS NMOS(LEVEL=1 VTO=0.7 KP=120u GAMMA=0.4 PHI=0.65 LAMBDA=0.04)
.dc Vgs 0 5 0.01 Vbs -3 0 1
.end
