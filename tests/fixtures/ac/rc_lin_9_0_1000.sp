* RC lowpass on lin frequency grid
* KNOWN GAP: non-DEC frequency sweeps are not yet supported by the shared analysis dispatcher.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: rc_lin_9_0_1000.expected.json
Vin in 0 DC 0 AC 1
R1 in out 1k
C1 out 0 1u
.ac lin 9 0 1000
.end
