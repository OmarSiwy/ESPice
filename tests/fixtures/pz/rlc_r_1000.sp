* RLC poles across under-, critical-, and overdamping
* KNOWN GAP: explicit PZ ports and transfer zeros are not yet exposed by the dispatcher.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: rlc_r_1000.expected.json
Vin in 0 0
R1 in a 1000
L1 a out 1m
C1 out 0 1u
.pz
.end
