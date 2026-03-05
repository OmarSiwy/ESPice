* Ideal lossless transmission line driven by a step, matched load.
* KNOWN GAP: nonzero transient output-start time is rejected by the dispatcher.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: bench_tline_ideal_tline.expected.json
* Origin: benchmark/fixtures/tline/ideal_tline/circuit.sp
Vin in 0 DC 0 PULSE(0 1 0 10p 10p 5n 10n)
RS in a 50
T1 a 0 b 0 Z0=50 TD=1n
RL b 0 50
.tran 10p 8n
.end
