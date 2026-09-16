* Fourier normalization and DC term
* Expected results: dc_only.expected.json
Vin out 0 DC -2
R1 out 0 1k
.tran .2u 5m 0 .2u
.four 1k v(out)
.end
