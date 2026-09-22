* Linear and quadratic resistor temperature coefficients
* KNOWN GAP: resistor temperature coefficients are not implemented by the current resistor model.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: resistor_tc_0_1e-05.expected.json
Vin in 0 10
R1 in out 1k
R2 out 0 3k tc1=0 tc2=1e-05
.temp -40 120 40
.end
