* Differential transfer function and differential output resistance
* KNOWN GAP: current-input/current-output or differential-output TF is not yet fully resolved.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: differential_output.expected.json
Vin in 0 1
R1 in a 1k
R2 a 0 3k
R3 in b 3k
R4 b 0 1k
.tf v(a,b) Vin
.end
