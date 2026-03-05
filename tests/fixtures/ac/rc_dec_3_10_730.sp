* RC lowpass on dec frequency grid
* KNOWN GAP: the current frequency helper stretches the grid to the stop instead of keeping the requested points-per-decade spacing.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: rc_dec_3_10_730.expected.json
Vin in 0 DC 0 AC 1
R1 in out 1k
C1 out 0 1u
.ac dec 3 10 730
.end
