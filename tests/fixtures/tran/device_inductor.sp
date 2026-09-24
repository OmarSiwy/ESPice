* RL current ramp: inductor branch variable in transient.
* Expected results: device_inductor.expected.json
* Origin: benchmark/fixtures/devices/inductor/circuit.sp
V1 in 0 DC 1
R1 in n1 10
L1 n1 0 1m
.tran 1u 0.5m
.end
