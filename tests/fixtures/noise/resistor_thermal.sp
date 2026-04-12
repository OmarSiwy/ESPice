* Resistor Thermal Noise Spectral Density
*
* Simple resistive voltage divider
* Thermal noise of R1 and R2 contributes to V(out)
* Expected noise PSD at output: 4*k*T*(R1||R2) = 4*1.38e-23*300*5k ~ 8.28e-17 V^2/Hz
* Flat (white) noise spectrum expected

V1 in 0 DC 5
R1 in out 10k
R2 out 0 10k

.NOISE V(out) V1 DEC 20 1 100MEG

.END
