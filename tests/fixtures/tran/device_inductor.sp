* RL current ramp: inductor branch variable in transient.
* KNOWN GAP: nonzero transient output-start time is rejected by the dispatcher.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: device_inductor.expected.json
* Origin: benchmark/fixtures/devices/inductor/circuit.sp
V1 in 0 DC 1
R1 in n1 10
L1 n1 0 1m
.tran 1u 0.5m
.end
