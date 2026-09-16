* PMOS Level 1 output characteristics: Ids vs Vsd at multiple Vsg.
* Expected results: device_mos1_pmos.expected.json
* Origin: benchmark/fixtures/devices/mos1_pmos/circuit.sp
* Tests PMOS polarity handling and parameter mapping.
Vsd 0 drain DC 0
Vsg 0 gate DC 0
M1 drain gate 0 0 PMOD W=20u L=1u
.model PMOD PMOS(LEVEL=1 VTO=-0.7 KP=60u GAMMA=0.4 PHI=0.65 LAMBDA=0.05)
.dc Vsd 0 5 0.025 Vsg 0 5 0.5
.end
