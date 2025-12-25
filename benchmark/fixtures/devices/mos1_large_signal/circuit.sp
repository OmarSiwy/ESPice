* NMOS Level 1 large-signal transient: CMOS inverter switching.
* Tests dynamic behavior with parasitic capacitances.
VDD vdd 0 DC 5
Vin in 0 PULSE(0 5 1n 0.5n 0.5n 10n 20n)
M1 out in vdd vdd PM W=20u L=1u
M2 out in 0 0 NM W=10u L=1u
CL out 0 1p
.model NM NMOS(LEVEL=1 VTO=0.7 KP=120u GAMMA=0.4 PHI=0.65 LAMBDA=0.04 CBD=20f CBS=20f CGSO=0.6n CGDO=0.6n)
.model PM PMOS(LEVEL=1 VTO=-0.7 KP=60u GAMMA=0.4 PHI=0.65 LAMBDA=0.05 CBD=20f CBS=20f CGSO=0.6n CGDO=0.6n)
.tran 0.05n 40n
.end
