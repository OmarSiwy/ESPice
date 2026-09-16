* Known nonlinear Fourier harmonics
* Expected results: polynomial_2.expected.json
Vin in 0 SIN(0 1 1k)
Bout out 0 V=V(in)^2
R1 out 0 1k
.tran .2u 5m 0 .2u
.four 1k v(out)
.end
