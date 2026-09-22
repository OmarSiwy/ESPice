* LTI periodic noise is independent of sideband truncation
* KNOWN GAP: periodic noise must distinguish genuine frequency conversion from an LTI circuit; extra LTI sidebands must not add noise.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: lti_rc_sidebands_1.expected.json
Vin in 0 AC 1 SIN(0 1 1k)
R1 in out 1k
C1 out 0 1u
.pnoise v(out) Vin dec 3 10 10k 1k 1
.end
