* m = 3 stamps what three parallel copies stamp (#48), against ngspice 45.
*   i(va) BSIM4 (LEVEL=54, no `m` parameter: the instance $mfactor) m=3
*   i(vb) the same BSIM4 as three copies
*   i(vc) MOS1 m=3, bulk reverse-biased: the junction gmin scales by m
*   i(vd) BJT m=3, base-collector reverse: gmin on the leakage leg
*   i(vj) JFET2 m=3, gate reverse: gmin on both gate junctions
*   i(vdi) diode m=3 on the instance, grading M=0.4 on the card: the
*          instance m multiplies, the card M stays the grading
* MOS1's junction gmin is NOT scaled by m in ngspice (mos1load.c:436-445),
* so i(vbulk) pins that too.
VG g 0 1.2
VA a 0 1
VB b 0 1
M1 a g 0 0 n4 W=1u L=100n m=3
M2 b g 0 0 n4 W=1u L=100n
M3 b g 0 0 n4 W=1u L=100n
M4 b g 0 0 n4 W=1u L=100n
VC c 0 2
VBULK bk 0 -1
M5 c 0 0 bk n1 W=10u L=1u m=3
VD d 0 3
Q1 d 0 0 qn m=3
VJ j 0 2
J1 j 0 0 jm m=3
VDI di 0 0.6
D1 di 0 dm m=3
.model dm D IS=1e-14 RS=10 M=0.4 CJO=1p
.model n4 NMOS LEVEL=54
.model n1 NMOS LEVEL=1 VTO=0.7 KP=1e-4 IS=1e-14
.model qn NPN IS=1e-16 BF=100
.model jm NJF LEVEL=2 VTO=-1.5 BETA=1e-3 IS=1e-14
.op
.end
