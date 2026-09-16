* Unit fixture: coupled inductors (1:1 transformer), sine drive.
* KNOWN GAP: nonzero transient output-start time is rejected by the dispatcher.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: device_kinduc.expected.json
* Origin: benchmark/fixtures/devices/kinduc/circuit.sp
Vin in 0 DC 0 SIN(0 1 10k)
Rs in p 50
L1 p 0 1m
L2 s 0 1m
K1 L1 L2 0.99
RL s 0 1k
.tran 1u 0.5m
.end
