* Honor the requested Fourier harmonic count
* Expected results: harmonic_count_1.expected.json
Vin out 0 SIN(0 1 1k)
R1 out 0 1k
.tran .2u 5m 0 .2u
.four 1k v(out) 1
.end
