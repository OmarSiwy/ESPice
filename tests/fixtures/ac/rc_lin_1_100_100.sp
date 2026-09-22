* RC lowpass on lin frequency grid
* KNOWN GAP: non-DEC frequency sweeps are not yet supported by the shared analysis dispatcher.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: rc_lin_1_100_100.expected.json
Vin in 0 DC 0 AC 1
R1 in out 1k
C1 out 0 1u
.ac lin 1 100 100
.end
