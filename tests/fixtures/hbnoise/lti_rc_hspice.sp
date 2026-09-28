* HSPICE form: .hbnoise takes its tone and sidebands from the .hb card
* Expected results: lti_rc_hspice.expected.json
Vin in 0 AC 1 SIN(0 1 1k)
R1 in out 1k
C1 out 0 1u
.hb 1k 7
.hbnoise v(out) Vin dec 3 10 10k
.end
