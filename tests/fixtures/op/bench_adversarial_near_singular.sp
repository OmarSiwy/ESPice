* Near-singular MNA: two huge resistors meeting at a weakly-grounded node.
* Expected results: bench_adversarial_near_singular.expected.json
* Origin: benchmark/fixtures/adversarial/near_singular/circuit.sp
* Exercises gmin stepping and ill-conditioned matrix handling.
V1 a 0 DC 1
R1 a b 1e12
R2 b 0 1e12
Rg b 0 1e15
.op
.end
