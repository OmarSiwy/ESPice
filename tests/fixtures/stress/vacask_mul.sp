* Diode voltage multiplier (VACASK benchmark)
* Expected results: vacask_mul.expected.json
* Origin: benchmark/fixtures/vacask/mul/circuit.sp
* ~500K timesteps, 4 diodes + 4 caps, Gear integration

.model D1N4007 D IS=76.9p RS=42.0m BV=1.00k IBV=5.00u CJO=26.5p M=0.333 N=1.45

.param c=100n

vs a 0 dc=0 sin 0 50 100k
r1 a 1 r=0.01
c1 1 2 c={c}
d1 0 2 d1n4007
c2 0 10 c={c}
d2 2 10 d1n4007
c3 2 3 c={c}
d3 10 3 d1n4007
c4 10 20 c={c}
d4 3 20 d1n4007

.options klu method=gear maxord=2

.tran 0.01u 5m 0 0.01u

.end
