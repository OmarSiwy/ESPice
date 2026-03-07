* Diode clamp on a logic line: limits overshoot to one diode drop above rail.
* KNOWN GAP: nonzero transient output-start time is rejected by the dispatcher.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: bench_digital_clamp.expected.json
* Origin: benchmark/fixtures/digital/clamp/circuit.sp
Vin in 0 DC 0 PULSE(0 6 0 1n 1n 20n 40n)
R1 in node 200
D1 node vdd DCLP
Vdd vdd 0 DC 3.3
C1 node 0 5p
.model DCLP D(IS=1e-14)
.tran 0.5n 80n
.end
