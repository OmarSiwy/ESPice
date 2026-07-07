* HSPICE MOSRA level 1: the aged operating point of an NMOS held at a fixed
* drain current. vd pins Vds = 1.5 V; h1/e1 servo the gate until
* i(vd) = -10 uA (loop gain 1e9 per amp), so Vgs - Vth is the same fresh and
* aged and the gate moves by exactly the aged delvto.
* BTI only, field- and temperature-independent (titfd = tittd = 0):
*   dVth = tit0*t^tn = 1e-4*(1e8)^0.25 = 0.01 V at RelTotalTime = 1e8 s,
* so v(g) aged = v(g) fresh + 0.01 V. SimMode 2 runs the .op fresh, then
* aged as "Operating Point (reltime=100000000)". UA = UB = UC = 0 keep
* BSIM3's mobility from depending on Vth; its remaining second-order
* couplings move the aged gate by under 2e-6 V more, inside atol 1e-5.
* Expected results: nmos_aged_vth.expected.json
vd d 0 1.5
vref r 0 -0.01
h1 x 0 vd 1k
e1 g 0 x r 1e6
m1 d g 0 0 n3 w=10u l=0.18u
.model n3 nmos(level=49 version=3.3 tnom=27 tox=4.1e-9 vth0=0.35 k1=0.53 k2=-0.06 k3=80 nlx=1.74e-7 vsat=1.5e5 ua=0 ub=0 uc=0 rdsw=200 u0=280 pclm=1.3 pdiblc1=0.39 pdiblc2=0.0086 nfactor=1.5 cdsc=0 voff=-0.1)
.model nra mosra level=1 tit0=1e-4 tn=0.25
.appendmodel nra mosra n3 nmos
.mosra reltotaltime=1e8 simmode=2
.tran 1n 10n
.op
.end
