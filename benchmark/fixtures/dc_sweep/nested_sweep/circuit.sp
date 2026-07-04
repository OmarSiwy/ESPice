* Nested DC sweep: NMOS Id vs Vds for several Vgs (output characteristics).
VDS d 0 DC 0
VGS g 0 DC 1
M1 d g 0 0 NMOS L=1u W=10u
.model NMOS NMOS(LEVEL=1 VTO=0.7 KP=120u)
.dc VDS 0 5 0.1 VGS 1 3 0.5
.end
