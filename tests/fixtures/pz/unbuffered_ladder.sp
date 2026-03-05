* Coupled two-state RC ladder
* KNOWN GAP: explicit PZ ports and transfer zeros are not yet exposed by the dispatcher.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: unbuffered_ladder.expected.json
Vin in 0 0
R1 in a 1k
C1 a 0 1u
R2 a out 1k
C2 out 0 1u
.pz
.end
