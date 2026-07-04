* CMOS Inverter VTC Sweep — find optimal PMOS width for symmetric switching
.model nch NMOS(level=1 VTO=0.7 KP=110u GAMMA=0.4 LAMBDA=0.04 PHI=0.65)
.model pch PMOS(level=1 VTO=-0.7 KP=50u GAMMA=0.57 LAMBDA=0.05 PHI=0.65)
Vdd vdd 0 DC 1.8
Vin in 0 DC 0.9
Mn1 out in 0 0 nch W=0.5u L=0.18u
Mp1 out in vdd vdd pch W=1u L=0.18u
.dc Vin 0 1.8 0.005
.end
