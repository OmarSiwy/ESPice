* 15 independent frequency points, vector batch tails
* KNOWN GAP: non-DEC frequency sweeps are not yet supported by the shared analysis dispatcher.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: lane_tail_15.expected.json
Vin in 0 AC 1
R1 in out 1k
C1 out 0 1u
.ac lin 15 10 10k
.end
