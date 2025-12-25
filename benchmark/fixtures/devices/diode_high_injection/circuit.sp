* Diode high injection and series resistance effects.
* Tests RS effect at high forward bias, where I*RS drop matters.
V1 anode 0 DC 0
D1 anode 0 DMOD
.model DMOD D(IS=1e-14 N=1 RS=50 IKF=10m)
.dc V1 0 2 0.005
.end
