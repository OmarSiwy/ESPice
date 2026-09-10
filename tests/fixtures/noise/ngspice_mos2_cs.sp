* MOS level 2 common-source noise against ngspice 45 (#156): channel
* thermal 4kT*(2/3)|gm| and the NLEV=2 default flicker
* KF*gm^2/(m*f^AF*W*Leff*Cox') (mos2noi.c:164-171). M2 (NLEV=3, gdsnoi)
* and M3 (NLEV=0, m=2) share the 100k load; M4 (NLEV=1) has its own.
* The output is v(d, d2) - v(d4).
VDD vdd 0 3
VG g 0 DC 1.2 AC 1
RL vdd d 10k
M1 d g 0 0 nm W=10u L=2u
RL2 vdd d2 100k
M2 d2 g 0 0 nm3 W=10u L=2u
M3 d2 g 0 0 nm0 W=10u L=2u m=2
RL4 vdd d4 30k
M4 d4 g 0 0 nm1 W=10u L=2u
E4 o 0 d d2 1
E5 o2 o d4 0 -1
.model nm NMOS LEVEL=2 VTO=0.7 KP=1e-4 GAMMA=0.4 PHI=0.6 NSUB=1e16 TOX=2e-8 RD=20 RS=20 KF=1e-26 AF=1.2
.model nm3 NMOS LEVEL=2 VTO=0.7 KP=1e-4 GAMMA=0.4 PHI=0.6 NSUB=1e16 TOX=2e-8 NLEV=3 GDSNOI=1.5
.model nm0 NMOS LEVEL=2 VTO=0.7 KP=1e-4 GAMMA=0.4 PHI=0.6 NSUB=1e16 TOX=2e-8 NLEV=0 KF=1e-26 AF=1.2
.model nm1 NMOS LEVEL=2 VTO=0.7 KP=1e-4 GAMMA=0.4 PHI=0.6 NSUB=1e16 KF=1e-26 AF=1.2 NLEV=1
.noise v(o2) VG dec 3 10 100meg
.end
