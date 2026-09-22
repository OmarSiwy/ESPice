* Current sweep in a circuit that also contains a voltage source
* KNOWN GAP: DC current sweeps are rejected when the deck also contains voltage sources.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: mixed_voltage_current.expected.json
Vbias bias 0 1
Iin 0 out 0
R1 out bias 1k
.dc Iin -1m 1m .5m
.end
