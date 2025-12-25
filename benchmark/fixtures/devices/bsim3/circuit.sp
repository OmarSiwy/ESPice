* Unit fixture: BSIM3v3 NMOS bias point (level 49, default params).
Vdd vdd 0 DC 1.8
Vg g 0 DC 1.0
Rd vdd d 10k
M1 d g 0 0 n3 W=10u L=0.18u
.model n3 NMOS(level=49 version=3.3.0)
.op
.end
