* Transfer poles and zeros with explicit input and output ports
* KNOWN GAP: explicit PZ ports and transfer zeros are not yet exposed by the dispatcher.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: rlc_notch_zeros.expected.json
Vin in 0 0
R1 in out 100
L1 out a 1m
C1 a 0 1u
.pz in 0 out 0 vol pz
.end
