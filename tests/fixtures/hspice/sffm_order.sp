* HSPICE SFFM(VO VA FC MDI FS) [CR SFFM]: the carrier frequency is third,
* unlike ngspice 44's SFFM(VO VA FM MDI FC). Oracle: analytic,
* v(a) = sin(2 pi 10M t + 0.5 sin(2 pi 1M t)) and, with MDI and FS
* omitted, v(b) = sin(2 pi 10M t).
* Expected results: sffm_order.expected.json
v1 a 0 sffm(0 1 10meg 0.5 1meg)
r1 a 0 1k
v2 b 0 sffm(0 1 10meg)
r2 b 0 1k
.tran 1n 2u
.end
