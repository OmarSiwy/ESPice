* Diode-clipped sine: generates odd harmonics for FFT validation.
Vin in 0 DC 0 SIN(0 2 1k)
R1 in out 1k
D1 out cap DC1
D2 cap2 out DC1
Vcap cap 0 DC 1
Vcap2 cap2 0 DC -1
.model DC1 D(IS=1e-14)
.tran 5u 5m
.four 1k v(out)
.end
