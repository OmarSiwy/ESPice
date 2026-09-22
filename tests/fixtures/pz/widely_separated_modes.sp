* Retain poles separated by twelve orders of magnitude
* KNOWN GAP: explicit PZ ports and transfer zeros are not yet exposed by the dispatcher.
* This correctness test should currently fail; implement support to match the expected output.
* KNOWN GAP: the pole solver can discard real fast poles using a relative eigenvalue cutoff.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: widely_separated_modes.expected.json
Vin in 0 0
R1 in a 1k
C1 a 0 1p
R2 in b 1k
C2 b 0 1
.pz
.end
