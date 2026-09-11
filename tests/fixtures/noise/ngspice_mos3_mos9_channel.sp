* MOS level 3 and level 9 channel thermal noise with RD/RS collapsed,
* against ngspice 45 (#155). Both read gm through ddx() inside the noise
* power, which was 0 until noisePsd ran on eval's family (#119), so only
* the 10k loads were heard. M1 (level 3, NLEV=2 flicker) and M2 (level 9,
* KF*Id^AF/(f*W*L*Cox'^2), mos9noi.c:97-103) drive separate loads; the
* output is v(d1) - v(d2).
VDD vdd 0 3
VG g 0 DC 1.2 AC 1
RL1 vdd d1 10k
M1 d1 g 0 0 m3 W=10u L=2u
RL2 vdd d2 20k
M2 d2 g 0 0 m9 W=10u L=2u
E1 o 0 d1 d2 1
.model m3 NMOS(LEVEL=3 VTO=0.7 KP=1e-4 GAMMA=0.4 PHI=0.6 NSUB=1e16 TOX=2e-8 KF=1e-26 AF=1)
.model m9 NMOS(LEVEL=9 VTO=0.7 KP=1e-4 GAMMA=0.4 PHI=0.6 NSUB=1e16 TOX=2e-8 KF=1e-27 AF=1)
.noise v(o) VG dec 2 100 100meg
.end
