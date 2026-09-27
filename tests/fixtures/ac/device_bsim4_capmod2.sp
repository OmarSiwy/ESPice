* BSIM4 capMod 2 gate charge: AC gate and drain currents of an NMOS biased on.
* Expected results: device_bsim4_capmod2.expected.json
* The default cvchargeMod 0 (BSIM4.8 manual, ngspice b4set.c) shapes VgsteffCV with noff and voffcv.
Vd d 0 DC 0.6
Vg g 0 DC 0.45 AC 1
M1 d g 0 0 n4 W=10u L=0.1u
.model n4 NMOS(level=54 noff=2 voffcv=-0.05)
.ac dec 1 1meg 100meg
.end
