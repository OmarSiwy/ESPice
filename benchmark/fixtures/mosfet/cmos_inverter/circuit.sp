* CMOS inverter DC transfer characteristic (Level-1 MOS).
VDD vdd 0 DC 5
Vin in 0 DC 0
M1 out in 0 0 NMOS L=1u W=10u
M2 out in vdd vdd PMOS L=1u W=20u
.model NMOS NMOS(LEVEL=1 VTO=0.7 KP=120u)
.model PMOS PMOS(LEVEL=1 VTO=-0.7 KP=60u)
.dc Vin 0 5 0.05
.end
