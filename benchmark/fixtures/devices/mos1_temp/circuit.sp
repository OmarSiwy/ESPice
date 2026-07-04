* NMOS Level 1 temperature dependence: transfer curve at multiple temps.
* Tests mobility and threshold voltage temperature models.
Vds drain 0 DC 3
Vgs gate 0 DC 0
M1 drain gate 0 0 NMOS W=10u L=1u
.model NMOS NMOS(LEVEL=1 VTO=0.7 KP=120u GAMMA=0.4 PHI=0.65 LAMBDA=0.04 TOX=40n UO=600)
.dc Vgs 0 5 0.01 TEMP -40 125 55
.end
