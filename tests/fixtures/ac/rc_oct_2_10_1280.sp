* RC lowpass on oct frequency grid
* KNOWN GAP: non-DEC frequency sweeps are not yet supported by the shared analysis dispatcher.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: rc_oct_2_10_1280.expected.json
Vin in 0 DC 0 AC 1
R1 in out 1k
C1 out 0 1u
.ac oct 2 10 1280
.end
