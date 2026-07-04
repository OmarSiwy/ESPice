* HB fixture: single-tone diode clipper, harmonic balance.
Vin in 0 DC 0 AC 1 SIN(0 2 1k)
R1 in out 1k
D1 out 0 dm
.model dm D(is=1e-14)
.hb 1k
.end
