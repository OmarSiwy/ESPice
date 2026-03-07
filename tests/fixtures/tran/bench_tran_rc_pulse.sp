* Transient fixture: pulse-driven RC network.
* KNOWN GAP: nonzero transient output-start time is rejected by the dispatcher.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: bench_tran_rc_pulse.expected.json
* Origin: benchmark/fixtures/tran/rc_pulse/circuit.sp
Vin in 0 PULSE(0 5 1u 100n 100n 5u 12u)
R1 in out 2k
C1 out 0 1n
.tran 0.1u 36u
.end
