* Golden four: clipped sine harmonics.
Vin in 0 DC 0 SIN(0 2 1k)
R1 in out 1k
D1 out 0 dm
.model dm D(is=1e-14)
.tran 10u 5m
.four 1k v(out)
.end
