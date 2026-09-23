* An unknown instance parameter fails the deck, as in ngspice 44.2 (#35).
* Expected results: unknown_instance_parameter.expected.json
* `ww=10u` is a typo for `w=10u`; running with the default width hides it.
VD d 0 5
VG g 0 2
M1 d g 0 0 nm ww=10u l=1u
.model nm nmos level=1 vto=1 kp=20u
.op
.end
