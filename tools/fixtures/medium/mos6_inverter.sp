* M05: MOS Level 6 CMOS Inverter — BSIM1 level models, VDD=5V
VDD vdd 0 DC 5
VIN in 0 PULSE(0 5 1n 0.5n 0.5n 10n 20n)
M1 out in 0 0 NMOD6 W=10u L=1u
M2 out in vdd vdd PMOD6 W=20u L=1u
CL out 0 0.1p
.MODEL NMOD6 NMOS (LEVEL=6 VTO=0.7 KP=110u TOX=20n)
.MODEL PMOD6 PMOS (LEVEL=6 VTO=-0.7 KP=50u TOX=20n)
.TRAN 0.1n 40n
.END
