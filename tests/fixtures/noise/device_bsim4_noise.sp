* BSIM4 (LEVEL=54) common-source noise against ngspice 45 (#80): default
* noise models (tnoiMod=0, fnoiMod=1 unified flicker), saturation.
VDD vdd 0 1.8
VG g 0 DC 0.9 AC 1
RL vdd d 5k
M1 d g 0 0 n4 W=10u L=0.5u
.model n4 NMOS LEVEL=54
.noise v(d) VG dec 3 10 10g
.end
