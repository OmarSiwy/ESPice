* MOS level 6 with neither KC nor TOX against ngspice 45 (#158): KC keeps
* its 5e-5 default (mos6set.c:48); only a given TOX derives it from U0
* (mos6temp.c:60-70). M2 gives TOX, so its KC = 0.5*U0*Cox'*1e-4.
VDD vdd 0 3
VG g 0 1
RD vdd d 10k
M1 d g 0 0 mm W=10u L=2u
RD2 vdd d2 10k
M2 d2 g 0 0 mt W=10u L=2u
.model mm NMOS(LEVEL=6)
.model mt NMOS(LEVEL=6 TOX=20n)
.op
.end
