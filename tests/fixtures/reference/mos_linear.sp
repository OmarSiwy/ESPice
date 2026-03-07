* Level-1 MOS linear
* Expected results: mos_linear.expected.json
Vg gate 0 2
Vd drain 0 0.1
Vb bulk 0 0
M1 drain gate 0 bulk nm W=10u L=1u
.model nm NMOS(level=1 vto=.7 kp=200u gamma=.4 phi=.6 lambda=.02 cgso=100p cgdo=100p)
.op
.options reltol=1e-6 abstol=1e-12 vntol=1e-8 method=gear temp=27 tnom=27
.end
