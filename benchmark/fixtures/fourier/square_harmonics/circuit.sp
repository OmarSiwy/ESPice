* Square-wave drive into RC: rich odd-harmonic spectrum for FFT checks.
Vin in 0 DC 0 PULSE(-1 1 0 1n 1n 0.5m 1m)
R1 in out 1k
C1 out 0 100n
.tran 5u 10m
.four 1k v(out)
.end
