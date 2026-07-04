* Level-1 NMOS in saturation: Shichman-Hodges DC operating point.
VDD d 0 DC 5
VGS g 0 DC 2
RD d drn 1k
M1 drn g 0 0 NMOS L=1u W=10u
.model NMOS NMOS(LEVEL=1 VTO=0.7 KP=120u)
.op
.end
