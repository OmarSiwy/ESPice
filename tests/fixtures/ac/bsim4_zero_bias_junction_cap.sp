* BSIM4 at exactly zero bias (#47): drain, source and bulk all at 0 V, so
* vbd = vbs = vds = 0. b4ld.c keeps capbd = czbd + czbdsw + czbdswg there,
* and keeps dVdseff/dVd (so the subthreshold gds and the channel cap
* survive) while zeroing Vdseff. The AC drain current of a drain stimulus
* is gds plus j*w*(the junction, channel and overlap caps); a zero-bias
* charge or Vdseff pinned to a constant dropped those terms.
VD d 0 DC 0 AC 1
VG g 0 0
M1 d g 0 0 n4 W=10u L=1u AD=10p AS=10p PD=22u PS=22u
.model n4 NMOS LEVEL=54 CJD=1e-3 CJSWD=1e-10 CJS=1e-3 CJSWS=1e-10
.ac dec 2 1meg 100meg
.end
