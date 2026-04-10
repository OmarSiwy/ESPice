* Resistor Thermal Noise — Sv = 4*k*T*R at T=300K
R1 1 0 10k
V1 1 0 DC 0 AC 1
.NOISE V(1) V1 DEC 10 1 1G
.END
