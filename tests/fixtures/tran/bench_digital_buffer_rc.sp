* Single-stage RC buffer driven by a logic pulse; rise/fall time check.
* KNOWN GAP: nonzero transient output-start time is rejected by the dispatcher.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: bench_digital_buffer_rc.expected.json
* Origin: benchmark/fixtures/digital/buffer_rc/circuit.sp
Vin in 0 DC 0 PULSE(0 3.3 0 100p 100p 10n 20n)
R1 in out 500
C1 out 0 20p
.tran 0.1n 60n
.end
