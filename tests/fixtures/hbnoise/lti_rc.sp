* LTI HB noise equals plain noise under a large drive
* Expected results: lti_rc.expected.json
Vin in 0 AC 1 SIN(0 10 1k)
R1 in out 1k
C1 out 0 1u
.hbnoise v(out) Vin dec 3 10 10k 1k 4 1
.end
