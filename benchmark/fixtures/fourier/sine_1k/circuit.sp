* Pure 1 kHz sine into a resistor: single-tone Fourier reference.
Vin in 0 DC 0 SIN(0 1 1k)
R1 in 0 1k
.tran 10u 5m
.four 1k v(in)
.end
