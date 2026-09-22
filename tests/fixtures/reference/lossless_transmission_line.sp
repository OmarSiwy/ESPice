* Matched line propagation delay and source termination
* Expected results: lossless_transmission_line.expected.json
Vin drive 0 PULSE(0 1 1n .1n .1n 10n 30n)
Rs drive a 50
T1 a 0 out 0 z0=50 td=2n
Rl out 0 50
.tran 10p 10n 0 10p
.options reltol=1e-6 abstol=1e-12 vntol=1e-8 method=gear temp=27 tnom=27
.end
