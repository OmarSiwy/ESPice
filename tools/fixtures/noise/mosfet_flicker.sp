* MOSFET Common-Source Amplifier — 1/f Flicker Noise
*
* VDD=3.3V, NMOS CS amplifier
* NMOS model includes KF and AF parameters for flicker noise
* Noise spectrum shows 1/f region at low frequencies
* transitioning to white (thermal) noise at higher frequencies
* Corner frequency depends on KF, gm, Cox, W, L

VDD vdd 0 DC 3.3
VIN g 0 DC 1.5 AC 1

RD vdd out 5k
M1 out g 0 0 NMOD W=10u L=1u

.MODEL NMOD NMOS (VTO=0.7 KP=110u KF=1e-25 AF=1)

.NOISE V(out) VIN DEC 20 1 100MEG

.END
