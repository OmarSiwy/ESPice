* Underdamped RLC ringing and inductor-current continuity
* Expected results: rlc_underdamped_step.expected.json
Vin in 0 PULSE(0 1 1u 10n 10n 1m 2m)
R1 in a 1
L1 a out 1m
C1 out 0 1u
.tran .1u 1m 0 .1u
.options reltol=1e-6 abstol=1e-12 vntol=1e-8 method=gear temp=27 tnom=27
.end
