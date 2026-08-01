* BSIM4 flicker noise in triode (#84): a 100k load pulls the drain to tens
* of mV, where Vds ~ Vdseff makes Eval1ovFNoise's DelClm negative; b4noi.c
* clamps it to 0.
VDD vdd 0 1.8
VG g 0 DC 1.5 AC 1
RL vdd d 100k
M1 d g 0 0 n4 W=10u L=0.5u
.model n4 NMOS LEVEL=54
.noise v(d) VG dec 3 10 10g
.end
