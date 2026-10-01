* E and G LAPLACE sources: H1(s) = 1/(1 + 1e-3 s) on E, H2(s) = 1/(1 + 1e-3 s
* + 1e-7 s^2) on G into 1 ohm, so v(b) = H1 v(a) and v(c) = -H2 v(a).
* Expected results: laplace_source.expected.json
* Oracle (analytic): DC gains 1 and -1; AC at 1, 10, 100, 1000 Hz from the
* closed forms with s = j 2 pi f.
v1 a 0 dc 1 ac 1
e1 b 0 laplace a 0 1 / 1 1e-3
r2 b 0 1k
g2 c 0 laplace a 0 1 / 1 1e-3 1e-7
r3 c 0 1
.op
.ac dec 1 1 1k
.end
