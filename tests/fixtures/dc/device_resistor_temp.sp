* Resistor temperature sweep: tests TC1, TC2 coefficients.
* KNOWN GAP: resistor and primary temperature DC sweep targets are not yet supported.
* This correctness test should currently fail; implement support to match the expected output.
* KNOWN GAP: resistor temperature coefficients are not implemented by the current resistor model.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: device_resistor_temp.expected.json
* Origin: benchmark/fixtures/devices/resistor_temp/circuit.sp
V1 a 0 DC 5
R1 a 0 1k tc1=3.9e-3 tc2=5.6e-7
.dc TEMP -40 125 5
.end
