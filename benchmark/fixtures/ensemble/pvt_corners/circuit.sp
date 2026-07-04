* Ensemble corners fixture: MOS inverter chain under PVT corner lanes.
Vdd vdd 0 DC 3.3
Vin in 0 DC 0 PULSE(0 3.3 1u 10n 10n 5u 10u)
M1 o1 in vdd vdd pm W=20u L=1u
M2 o1 in 0 0 nm W=10u L=1u
M3 o2 o1 vdd vdd pm W=20u L=1u
M4 o2 o1 0 0 nm W=10u L=1u
M5 out o2 vdd vdd pm W=20u L=1u
M6 out o2 0 0 nm W=10u L=1u
CL out 0 100f
.model nm NMOS(level=1 vto=0.7 kp=60u lambda=0.02)
.model pm PMOS(level=1 vto=-0.7 kp=25u lambda=0.02)
.tran 10n 20u
.end
