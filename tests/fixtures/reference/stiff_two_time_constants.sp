* Separated nanosecond and millisecond dynamics
* Expected results: stiff_two_time_constants.expected.json
Vin in 0 PULSE(0 1 1u 1n 1n 1 2)
R1 in fast 1k
C1 fast 0 1p
R2 in slow 1k
C2 slow 0 1u
.tran 10n 10u 0 10n
.options reltol=1e-6 abstol=1e-12 vntol=1e-8 method=gear temp=27 tnom=27
.end
