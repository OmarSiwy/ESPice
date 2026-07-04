* HFET2 (heterojunction FET level 2) DC operating point.
* ngspice: Z device with NHFET model type, level=2.
Vdd vdd 0 DC 3
Vg g 0 DC 0
Rd vdd d 500
Z1 d g 0 nhf2
.model nhf2 NHFET(LEVEL=2 VTO=0.15 LAMBDA=0.15 MU=0.4 DI=4e-8 DELTA=3 VS=1.5e5 ETA=1.28 M=3 SIGMA0=0.057)
.op
.end
