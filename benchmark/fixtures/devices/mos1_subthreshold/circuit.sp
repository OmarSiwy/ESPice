* NMOS Level 1 subthreshold region: near and below Vth.
* Fine-grained sweep around threshold for accurate transition check.
Vds drain 0 DC 1
Vgs gate 0 DC 0
M1 drain gate 0 0 NMOS W=10u L=2u
.model NMOS NMOS(LEVEL=1 VTO=0.7 KP=120u GAMMA=0.4 PHI=0.65 LAMBDA=0.04)
.dc Vgs 0 1.5 0.002
.end
