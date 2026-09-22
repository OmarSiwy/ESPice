* Current-input DC transimpedance
* KNOWN GAP: current-input/current-output or differential-output TF is not yet fully resolved.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: current_input.expected.json
Iin 0 out 1m
R1 out 0 2k
.tf v(out) Iin
.end
