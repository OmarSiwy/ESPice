* CMOS inverter tran
* Expected results: cmos_inverter_tran.expected.json
Vdd vdd 0 3.3
Vin in 0 DC 0 AC 1 PULSE(0 3.3 1n .1n .1n 5n 10n)
Mp out in vdd vdd pm W=20u L=1u
Mn out in 0 0 nm W=10u L=1u
Cl out 0 1p
.model nm NMOS(level=1 vto=.7 kp=200u lambda=.02)
.model pm PMOS(level=1 vto=-.7 kp=100u lambda=.02)
.tran 5p 30n 0 5p
.options reltol=1e-6 abstol=1e-12 vntol=1e-8 method=gear temp=27 tnom=27
.end
