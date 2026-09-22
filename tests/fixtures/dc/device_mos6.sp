* NMOS Level 6 output and transfer characteristics.
* Expected results: device_mos6.expected.json
* Origin: benchmark/fixtures/devices/mos6/circuit.sp
* Tests threshold voltage dependence model.
Vds drain 0 DC 0
Vgs gate 0 DC 0
M1 drain gate 0 0 NMOD W=10u L=1u
.model NMOD NMOS(LEVEL=6 VTO=0.7  GAMMA=0.4 PHI=0.65 LAMBDA=0.04 KV=1  TOX=40n)
.dc Vds 0 5 0.025 Vgs 0 5 0.5
.end
