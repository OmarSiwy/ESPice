* HSPICE MOSRA level 1: BTI Arrhenius factor at each device's temperature.
* Three mos3 NMOS at the same constant stress (Vgs = 1.2 V, Vds = 1.5 V),
* BTI only, field-independent (titfd = 0), tittd = 3000 K:
*   dVth = tit0*exp(-tittd/T)*t^tn = 1e-2*exp(-3000/T)*(1e8)^0.25
* with T the device temperature in kelvin: the circuit's 25 C (HSPICE runs
* at TNOM, 25 C, without .temp) plus dtemp,
* unless the card gives temp, which wins (mos3 and ngspice's rule):
*   m1 dtemp=0            T = 298.15 K
*   m2 dtemp=50           T = 348.15 K
*   m3 temp=100 dtemp=50  T = 373.15 K
* so dVth(m2)/dVth(m1) = exp(3000*(1/298.15 - 1/348.15)).
* Expected results: nmos_dtemp_arrhenius.expected.json
vd d 0 1.5
vg g 0 1.2
m1 d g 0 0 n3 w=10u l=1u
m2 d g 0 0 n3 w=10u l=1u dtemp=50
m3 d g 0 0 n3 w=10u l=1u temp=100 dtemp=50
.model n3 nmos level=3 vto=0.7 kp=1e-4
.model nra mosra level=1 tit0=1e-2 tittd=3000 tn=0.25
.appendmodel nra mosra n3 nmos
.mosra reltotaltime=1e8 simmode=0
.tran 1n 10n
.end
