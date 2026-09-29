* HSPICE RF .hblin: frequency-translation S-parameters of two square-law
* MOSFET mixers in saturation, gate on the RF port, source pumped by a 1 MHz
* LO, so gm(t) = beta (1 - 0.5 sin(w0 t)). P1 reads the input band f, P2 the
* lower sideband f0 - f (1 nF across it), P3 the upper sideband f0 + f.
* Oracle: analytic (see the expected.json derivation).
* Expected results: hblin_mixer.expected.json
P1 rf 0 port=1 z0=50 dc=2
vlo lo 0 sin(0 0.5 1meg)
m1 if rf lo 0 nm w=10u l=1u
c1 if 0 1n
P2 if 0 port=2 z0=50 dc=5 hblin=[1, -1]
m2 up rf lo 0 nm w=20u l=1u
P3 up 0 port=3 z0=50 dc=5 hblin=[1, 1]
.model nm nmos level=1 vto=1 kp=1e-4 lambda=0 gamma=0
.hb 1meg 4
.hblin poi 3 10k 100k 200k
.end
