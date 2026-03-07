* Positive-feedback comparator (Schmitt-style) with hysteresis: latch-prone DC.
* Expected results: bench_schmitt.expected.json
* Origin: benchmark/fixtures/convergence/schmitt/circuit.sp
VCC vcc 0 DC 5
Vin in 0 DC 2.5
R1 out fb 10k
R2 fb 0 10k
E1 out 0 fb in 1e5
.op
.end
