* vntol and chgtol of 0 run, as ngspice runs them (#150)
* Expected results: zero_vntol_chgtol.expected.json
V1 in 0 pulse(0 1 0 1n 1n 1u 2u)
R1 in out 1k
C1 out 0 1n
D1 out 0 dmod
.model dmod d
.options vntol=0 chgtol=0
.tran 10n 2u
.meas tran vend find v(out) at=2u
.end
