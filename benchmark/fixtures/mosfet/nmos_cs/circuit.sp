* NMOS common-source amplifier, resistor load, transient drive.
VDD vdd 0 DC 5
Vin in 0 DC 1.5 PULSE(1.2 1.8 0 1u 1u 5u 12u)
RD vdd out 2k
M1 out in 0 0 NMOS L=1u W=20u
.model NMOS NMOS(LEVEL=1 VTO=0.7 KP=120u LAMBDA=0.02)
.tran 0.1u 24u
.end
