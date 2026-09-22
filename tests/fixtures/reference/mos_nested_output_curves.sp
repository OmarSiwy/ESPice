* MOS output curves across cutoff, triode and saturation
* Expected results: mos_nested_output_curves.expected.json
Vg gate 0 0
Vd drain 0 0
M1 drain gate 0 0 nm W=10u L=1u
.model nm NMOS(level=1 vto=.7 kp=200u gamma=.4 phi=.6 lambda=.02 cgso=100p cgdo=100p)
.dc Vd 0 3 .25 Vg 0 3 .5
.options reltol=1e-6 abstol=1e-12 vntol=1e-8 method=gear temp=27 tnom=27
.end
