* HFET2 output characteristics: Id vs Vds at multiple Vgs.
* Tests heterojunction FET level 2 physics with enhanced modeling.
Vds drain 0 DC 0
Vgs gate 0 DC 0
Z1 drain gate 0 nhf2
.model nhf2 NHFET(LEVEL=2 VTO=0.15 LAMBDA=0.15 MU=0.4 DI=4e-8 DELTA=3 VS=1.5e5 ETA=1.28 M=3 SIGMA0=0.057)
.dc Vds 0 3 0.02 Vgs -0.5 0.5 0.1
.end
