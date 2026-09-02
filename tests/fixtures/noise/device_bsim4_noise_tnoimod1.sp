* KNOWN GAP: tnoiMod=1 needs Gm/Gds/Gmb at the noise point; bsim4va.va takes them from its own NOISE_DERIVATIVES path, which is commented out there, not from ddx()
* BSIM4 tnoiMod=1 (holistic thermal noise), fnoiMod=0, with source/drain
* resistance, against ngspice 45 (#80): b4noi.c clamps npart_theta to 0.9
* (and 0.9*npart_beta) and multiplies gspr by (1 + theta^2*gspr/IdovVds);
* the Rd/Rs rows match, the channel row waits on #119.
VDD vdd 0 1.8
VG g 0 DC 0.9 AC 1
RL vdd d 5k
M1 d g 0 0 n4 W=10u L=0.5u NF=2
.model n4 NMOS LEVEL=54 TNOIMOD=1 FNOIMOD=0 RDSMOD=1 RSH=10 RDSWMIN=100 RDSW=200 RNOIB=1.2
.noise v(d) VG dec 3 10 10g
.end
