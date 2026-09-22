* Current-output DC transconductance
* KNOWN GAP: current-input/current-output or differential-output TF is not yet fully resolved.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: current_output.expected.json
Vin in 0 1
R1 in out 1k
Vmeasure out 0 0
.tf i(Vmeasure) Vin
.end
