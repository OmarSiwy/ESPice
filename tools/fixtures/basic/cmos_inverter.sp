* CMOS Inverter — Level 1 MOSFETs
VDD vdd 0 DC 3.3
VIN in 0 DC 0.7
M1 out in 0 0 NMOD W=10u L=1u
M2 out in vdd vdd PMOD W=20u L=1u
.MODEL NMOD NMOS (VTO=0.5 KP=120u)
.MODEL PMOD PMOS (VTO=-0.5 KP=60u)
.OP
.END
