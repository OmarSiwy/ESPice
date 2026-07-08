* E POLE sources in transient: the step response of a real pole and of a
* complex pole pair.
* Expected results: pole_step.expected.json
* Oracle (analytic): v(a) steps 0 -> 1 V over 1 ns (a 0.5 ns delay, below
* the tolerance).
*   e1: H1 = 1e3 / (s + 1e3), v(b) = 1 - exp(-1e3 t).
*   e2: H2 = 1.25e6 / ((s + 500)^2 + wd^2), wd = 2 pi 159.154943091895, so
*       v(c) = K (1 - exp(-500 t) (cos(wd t) + 500/wd sin(wd t))) with
*       K = 1.25e6 / (500^2 + wd^2).
v1 a 0 pwl(0 0 1n 1)
e1 b 0 pole a 0 1e3 / 1 1e3,0
e2 c 0 pole a 0 1.25e6 / 1 500,159.154943091895 500,-159.154943091895
.tran 5u 10m
.end
