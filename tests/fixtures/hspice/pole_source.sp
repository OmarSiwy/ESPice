* E and G POLE sources [SA E-element Pole-Zero Function]:
* H(s) = a (s - z1)...(s - zn) / (b (s - p1)...(s - pm)), each root written
* `alpha, f` for s = -alpha + j 2 pi f.
* Expected results: pole_source.expected.json
* Oracle (analytic), DC gain H(0) and AC at 1 Hz .. 10 kHz from the closed
* forms at s = j 2 pi f, v(a) = 1:
*   e1: H1 = 1e4 (s + 1e3) / ((s + 1e2)(s + 1e4)), real roots, H1(0) = 10.
*   g2: H2 = 4e7 / (2 ((s + 1e3)^2 + (2 pi 1e3)^2)), a complex pole pair,
*       into 1 ohm, so v(c) = -H2.
*   e3: H3 = s / (s + 1e3), a zero at the origin (the manual's high-pass).
*   e4: H4 = (s^2 + (2 pi 100)^2) / (s + 500)^2, a complex zero pair: a
*       notch, v(e) = 0 at 100 Hz.
v1 a 0 dc 1 ac 1
e1 b 0 pole a 0 1e4 1e3,0 / 1 1e2,0 1e4,0
r1 b 0 1k
g2 c 0 pole a 0 4e7 / 2 1e3,1e3 1e3,-1e3
r2 c 0 1
e3 d 0 pole a 0 1 0,0 / 1 1e3,0
e4 e 0 pole a 0 1 0,100 0,-100 / 1 500,0 500,0
.op
.ac dec 1 1 10k
.end
