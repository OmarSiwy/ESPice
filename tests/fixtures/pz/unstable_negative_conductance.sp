* Unstable pole must not be hidden
* KNOWN GAP: explicit PZ ports and transfer zeros are not yet exposed by the dispatcher.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: unstable_negative_conductance.expected.json
R1 out 0 1k
G1 out 0 out 0 -.002
C1 out 0 1u
.pz
.end
