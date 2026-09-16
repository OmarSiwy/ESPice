* NPN current mirror: reference current copied to the output branch.
* Expected results: bench_analog_current_mirror.expected.json
* Origin: benchmark/fixtures/analog/current_mirror/circuit.sp
VCC vcc 0 DC 5
Iref vcc ref DC 1m
RL vcc out 1k
Q1 ref ref 0 QN
Q2 out ref 0 QN
.model QN NPN(IS=1e-16 BF=200)
.op
.end
