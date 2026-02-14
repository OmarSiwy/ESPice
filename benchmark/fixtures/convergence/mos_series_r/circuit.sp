* MOSFETs with non-zero RD/RS, so the internal drain/source nodes are live.
*
* This deck exists to be the counter-case for derivative-width narrowing.
* docs/perf/remaining-2026-09-10.md records that mos1's smallest CORRECT
* lane universe is SIX, not four, precisely because the rd/rs series
* branches touch {d,di} and {s,si} -- and that a k=4 universe is provably
* wrong, with 3150 bit mismatches measured at rd=12, rs=9.
*
* Those are the values used below, deliberately. Any change that assumes
* di === d and si === s -- the rank-4 collapse specialisation, an instance
* partition that mis-sorts, a narrowed Dual width -- produces wrong
* currents here and nowhere else in the corpus. Every other MOSFET deck in
* the suite leaves RD/RS at zero, which is exactly why the assumption
* looks safe until it is not.
*
* The sweep walks the device from cutoff through linear into saturation so
* the series drop matters over its whole range, not just at one bias.
Vdd vdd 0 DC 5
Vg  g   0 DC 2
Rd  vdd d 200
M1  d g s 0 NRS L=1U W=20U
Rs  s 0 50
M2  d2 g 0 0 NRS L=1U W=20U
Rd2 vdd d2 200
.model NRS NMOS(LEVEL=1 VTO=0.7 KP=110U GAMMA=0.4 LAMBDA=0.04 PHI=0.65
+ RD=12 RS=9)
.dc Vg 0 5 0.05
.end
