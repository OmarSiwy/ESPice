* Sweep a resistor instance value
* KNOWN GAP: resistor and primary temperature DC sweep targets are not yet supported.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: resistor_sweep.expected.json
Vin in 0 1
R1 in out 1k
R2 out 0 1k
.dc R2 1k 5k 1k
.end
