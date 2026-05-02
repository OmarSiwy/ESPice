* LTI periodic noise is independent of sideband truncation
* Expected results: lti_rc_sidebands_7.expected.json
Vin in 0 AC 1 SIN(0 1 1k)
R1 in out 1k
C1 out 0 1u
.pnoise v(out) Vin dec 3 10 10k 1k 7
.end
