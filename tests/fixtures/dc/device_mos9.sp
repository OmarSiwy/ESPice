* NMOS Level 9 output and transfer characteristics.
* Expected results: device_mos9.expected.json
* Origin: benchmark/fixtures/devices/mos9/circuit.sp
Vds drain 0 DC 0
Vgs gate 0 DC 0
M1 drain gate 0 0 NMOD W=10u L=1u
.model NMOD NMOS(LEVEL=9 VTO=0.7 KP=120u GAMMA=0.4 PHI=0.65  TOX=40n)
.dc Vds 0 5 0.025 Vgs 0 5 0.5
.end
