* Fourier normalization and DC term
* Expected results: offset.expected.json
Vin out 0 SIN(2 1 1k)
R1 out 0 1k
.tran .2u 5m 0 .2u
.four 1k v(out)
.end
