* Very small series resistor (1 micro-ohm) acting as a near-ideal short.
* Expected results: bench_adversarial_tiny_resistor.expected.json
* Origin: benchmark/fixtures/adversarial/tiny_resistor/circuit.sp
* Tests conductance blow-up without producing an actual singular matrix.
V1 a 0 DC 2
R1 a b 1e-6
R2 b 0 1k
.op
.end
