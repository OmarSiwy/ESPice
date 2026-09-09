* MOS level 3 common-source noise against ngspice 45 (#84): RD/RS thermal,
* channel thermal (NLEV=2 default: 4kT*(2/3)|gm|) and flicker
* KF*gm^2/(m*f^AF*W*Leff*Cox'), plus the 10k load. M1 runs saturated,
* M2 (NLEV=3, gdsnoi) and M3 (NLEV=1, m=2) share the 100k load, so both
* run linear; the output is v(d, d2).
VDD vdd 0 5
VG g 0 DC 1.5 AC 1
RL vdd d 10k
M1 d g 0 0 nm W=20u L=2u
RL2 vdd d2 100k
M2 d2 g 0 0 nm3 W=20u L=2u
M3 d2 g 0 0 nm1 W=20u L=2u m=2
.model nm NMOS LEVEL=3 VTO=0.8 KP=5e-5 TOX=20n RD=20 RS=20 KF=1e-25 AF=1.2
.model nm3 NMOS LEVEL=3 VTO=0.8 KP=5e-5 TOX=20n RD=20 RS=20 NLEV=3 GDSNOI=1.5
.model nm1 NMOS LEVEL=3 VTO=0.8 KP=5e-5 TOX=20n NLEV=1 KF=1e-25 AF=1.2
.noise v(d,d2) VG dec 3 10 100meg
.end
