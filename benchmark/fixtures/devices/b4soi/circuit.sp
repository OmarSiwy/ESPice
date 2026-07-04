* BSIM4SOI NMOS operating point.
* ngspice: NMOS level=58, 4 terminals (D G S E).
Vdd vdd 0 DC 1.1
Vg g 0 DC 0.7
Vb body 0 DC 0
Rd vdd d 10k
M1 d g 0 body nb4soi W=1u L=0.1u
.model nb4soi NMOS(LEVEL=58 VERSION=4.4 TNOM=27 TOXE=1.8e-9 TOXP=1.5e-9 VTH0=0.3 K1=0.5 K2=-0.1 VSAT=1.5e5 U0=300 RDSW=200)
.op
.end
