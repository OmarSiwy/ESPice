* HSPICE RF .hblin noisecalc=1: the single-sideband noise figure of an ideal
* multiplying mixer. i(if) = 0.1 v(lo) v(rf) with v(lo) = sin(w0 t), RF port
* P1 shunted by R1 = 50, IF port P2 (lower band f0 - f) shunted by R2 = 50,
* all at 290 K. Each of the signal band f and the image 2 f0 - f brings
* 100 kT of RF-node noise (P1's z0 and R1, 50 kT each) through the
* conversion gain (25 * 0.05)^2; R2 adds 50 kT at the IF node, so
* F = (2 * 100 + 50 / 1.25^2) / 50 = 4.64.
* Oracle: analytic (see the expected.json derivation).
* Expected results: hblin_noise.expected.json
P1 rf 0 port=1 z0=50
R1 rf 0 50
vlo lo 0 sin(0 1 1meg)
g1 0 if cur='0.1*v(lo)*v(rf)'
P2 if 0 port=2 z0=50 hblin=[1, -1]
R2 if 0 50
.temp 16.85
.hb 1meg 4
.hblin poi 2 10k 100k noisecalc=1
.end
