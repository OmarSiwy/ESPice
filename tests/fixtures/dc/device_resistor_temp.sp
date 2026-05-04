* Resistor temperature sweep: tests TC1, TC2 coefficients.
* Expected results: device_resistor_temp.expected.json
* Origin: benchmark/fixtures/devices/resistor_temp/circuit.sp
V1 a 0 DC 5
R1 a 0 1k tc1=3.9e-3 tc2=5.6e-7
.dc TEMP -40 125 5
.end
