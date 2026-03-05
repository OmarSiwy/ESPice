* MOS amplifier gain, output resistance and high-frequency poles
* Expected results: mos_common_source_ac.expected.json
Vdd vdd 0 5
Vin gate 0 DC 1.5 AC 1
Rd vdd out 2k
M1 out gate 0 0 nm W=10u L=1u
Cl out 0 10p
.model nm NMOS(level=1 vto=.7 kp=200u gamma=.4 phi=.6 lambda=.02 cgso=100p cgdo=100p)
.ac dec 5 1 1g
.options reltol=1e-6 abstol=1e-12 vntol=1e-8 method=gear temp=27 tnom=27
.end
