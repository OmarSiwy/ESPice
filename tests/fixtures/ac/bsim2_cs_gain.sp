* BSIM2 (LEVEL=5) common-source AC gain against ngspice 45 (#157). With
* RSH = 0 the drain and source nodes collapse (b2set.c:486); a 1e12 S
* stand-in short rounded gds to ulp(1e12) and cut the gain to 0.4x.
* M2 has RSH=50 NRD=NRS=1, so its series resistors stay.
VDD vdd 0 3
VG g 0 DC 1.2 AC 1
RD vdd d 10k
M1 d g 0 0 mm W=10u L=2u
RD2 vdd d2 10k
M2 d2 g 0 0 mr W=10u L=2u NRD=1 NRS=1
.model mm NMOS(LEVEL=5)
.model mr NMOS(LEVEL=5 RSH=50)
.ac dec 2 1k 100meg
.end
