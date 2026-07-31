* MOS levels 1, 2, 3, 6 and 9: card spellings and temperature rules that
* ngspice 45 accepts (#114). One NMOS per drain source; every current is
* i(vdN). Each device pins one row of the issue:
*   d1  LEVEL 2, U0 (only uo was read)        d2  LEVEL 9, U0
*   d3  LEVEL 1, UO (only u0 was read)        d4  LEVEL 3, UO
*   d5  LEVEL 6, UO (the KC default)
*   d6  LEVEL 3, DELVT0                       d7  LEVEL 9, DELVT0
*   d8  LEVEL 1, instance temp=80             d9  LEVEL 2, instance dtemp=30
*   d10 LEVEL 6, instance temp=80             d11 LEVEL 9, instance temp=80
*   d12 LEVEL 6, TNOM=50 (degrees C, not kelvin)
*   d13 LEVEL 3, NSUB with TNOM=50 (PHI from ni(TNOM))
*   d14 LEVEL 9, NSUB with TNOM=50
*   d15 LEVEL 2, VMAX at instance temp=80 (velocity saturation with the
*       mobility at TNOM)
*   d16 LEVEL 6, LAMBDA0=0 given (no fallback to LAMBDA)
VG g 0 1.5
VD1 d1 0 2
VD2 d2 0 2
VD3 d3 0 2
VD4 d4 0 2
VD5 d5 0 2
VD6 d6 0 2
VD7 d7 0 2
VD8 d8 0 2
VD9 d9 0 2
VD10 d10 0 2
VD11 d11 0 2
VD12 d12 0 2
VD13 d13 0 2
VD14 d14 0 2
VD15 d15 0 2
VD16 d16 0 2
M1 d1 g 0 0 m2u0 W=10u L=2u
M2 d2 g 0 0 m9u0 W=10u L=2u
M3 d3 g 0 0 m1uo W=10u L=2u
M4 d4 g 0 0 m3uo W=10u L=2u
M5 d5 g 0 0 m6uo W=10u L=2u
M6 d6 g 0 0 m3d W=10u L=2u
M7 d7 g 0 0 m9d W=10u L=2u
M8 d8 g 0 0 m1t W=10u L=2u temp=80
M9 d9 g 0 0 m2t W=10u L=2u dtemp=30
M10 d10 g 0 0 m6t W=10u L=2u temp=80
M11 d11 g 0 0 m9t W=10u L=2u temp=80
M12 d12 g 0 0 m6tn W=10u L=2u
M13 d13 g 0 0 m3ni W=10u L=2u
M14 d14 g 0 0 m9ni W=10u L=2u
M15 d15 g 0 0 m2v W=10u L=2u temp=80
M16 d16 g 0 0 m6l W=10u L=2u
.model m2u0 NMOS LEVEL=2 VTO=0.7 TOX=20n U0=300
.model m9u0 NMOS LEVEL=9 VTO=0.7 TOX=20n U0=300
.model m1uo NMOS LEVEL=1 VTO=0.7 TOX=20n UO=300
.model m3uo NMOS LEVEL=3 VTO=0.7 TOX=20n UO=300
.model m6uo NMOS LEVEL=6 VTO=0.7 TOX=20n UO=300
.model m3d NMOS LEVEL=3 VTO=0.7 KP=50u DELVT0=0.1
.model m9d NMOS LEVEL=9 VTO=0.7 KP=50u DELVT0=0.1
.model m1t NMOS LEVEL=1 VTO=0.7 KP=50u LAMBDA=0.02
.model m2t NMOS LEVEL=2 VTO=0.7 KP=50u LAMBDA=0.02
.model m6t NMOS LEVEL=6 VTO=0.7 KV=2 NV=1.5 KC=5e-5 NC=1.5 LAMBDA=0.02
.model m9t NMOS LEVEL=9 VTO=0.7 KP=50u
.model m6tn NMOS LEVEL=6 VTO=0.7 KV=2 NV=1.5 KC=5e-5 NC=1.5 TNOM=50
.model m3ni NMOS LEVEL=3 TOX=20n NSUB=1e16 UO=500 TNOM=50
.model m9ni NMOS LEVEL=9 TOX=20n NSUB=1e16 UO=500 TNOM=50
.model m2v NMOS LEVEL=2 VTO=0.7 TOX=20n UO=500 VMAX=5e4 NEFF=1
.model m6l NMOS LEVEL=6 VTO=0.7 KV=2 NV=1.5 KC=5e-5 NC=1.5 LAMBDA=0.05 LAMBDA0=0
.op
.end
