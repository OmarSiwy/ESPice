* Known nonlinear Fourier harmonics
* KNOWN GAP: the behavioral-source compiler only supports a limited single-control polynomial subset.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: polynomial_3.expected.json
Vin in 0 SIN(0 1 1k)
Bout out 0 V=V(in)^3
R1 out 0 1k
.tran .2u 5m 0 .2u
.four 1k v(out)
.end
