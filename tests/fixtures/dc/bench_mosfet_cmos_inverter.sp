* CMOS inverter DC transfer characteristic (Level-1 MOS).
* Expected results: bench_mosfet_cmos_inverter.expected.json
* Origin: benchmark/fixtures/mosfet/cmos_inverter/circuit.sp
* LAMBDA=0.01 breaks the exact balance of the original (KP*W equal, LAMBDA=0):
* there every vout in the both-saturated band solved KCL at vin = 2.5 V and
* the oracle pinned wherever ngspice's Newton stopped. Now the point is unique.
VDD vdd 0 DC 5
Vin in 0 DC 0
M1 out in 0 0 NMOS L=1u W=10u
M2 out in vdd vdd PMOS L=1u W=20u
.model NMOS NMOS(LEVEL=1 VTO=0.7 KP=120u LAMBDA=0.01)
.model PMOS PMOS(LEVEL=1 VTO=-0.7 KP=60u LAMBDA=0.01)
.dc Vin 0 5 0.05
.end
