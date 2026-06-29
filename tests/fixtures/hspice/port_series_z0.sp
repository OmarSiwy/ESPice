* HSPICE P element: z0 sits in series with the port source in DC and
* transient too [SA Ch.17], not only inside .lin. P1 (1 V, 50 ohm) into
* 150 ohm gives v(a) = 0.75 V; P2 (1 V step, 1 kohm) charges 1 nF, so
* v(b) = 1 - exp(-t / 1 us).
* Oracle: analytic (see the expected.json derivation).
* Expected results: port_series_z0.expected.json
P1 a 0 port=1 z0=50 dc=1
R1 a 0 150
P2 b 0 port=2 z0=1k pulse(0 1 0 1p 1p 1 2)
C2 b 0 1n
.op
.tran 10n 3u
.end
