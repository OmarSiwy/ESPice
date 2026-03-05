* Ideal delay line into a high impedance: pure transport delay observation.
* KNOWN GAP: nonzero transient output-start time is rejected by the dispatcher.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: bench_tline_delay_line.expected.json
* Origin: benchmark/fixtures/tline/delay_line/circuit.sp
Vin in 0 DC 0 PULSE(0 2 0 50p 50p 2n 8n)
RS in a 75
T1 a 0 b 0 Z0=75 TD=2n
RL b 0 1meg
.tran 20p 12n
.end
