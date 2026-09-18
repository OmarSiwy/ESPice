* K coupling reaches the stamp in full f64 (#89): with an open secondary,
* v(b)/v(a) = M/L1 = k*sqrt(L1*L2)/L1 = k = 0.3 exactly. Rounding k or M
* through f32 moved it to 0.30000001.
* ngspice-45: v(b) = 3.000000e-01, -1.71531e-12 (the 1e12 ohm load).
V1 a 0 ac 1
L1 a 0 1u
L2 b 0 1u
R2 b 0 1e12
K1 L1 L2 0.3
.ac lin 1 1meg 1meg
.end
