* Absolute Fourier phase relative to simulation time origin
* Expected results: phase_0.expected.json
Vin out 0 SIN(0 1 1k 0 0 0)
R1 out 0 1k
.tran .2u 5m 0 .2u
.four 1k v(out)
.end
