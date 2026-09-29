* HSPICE .snac <sweep> [CR .SNAC] runs as .pac at the .sn tone.
* Oracle: pac/rc's, analytic: an LTI circuit has no sidebands, so
* sideband 0 is the ordinary H(f) = 1/(1 + j*2*pi*f*RC).
* Expected results: snac_rc.expected.json
Vin in 0 AC 1 SIN(0 1 1k)
R1 in out 1k
C1 out 0 1u
.sn tone=1k nharms=8
.snac dec 4 10 10k
.end
