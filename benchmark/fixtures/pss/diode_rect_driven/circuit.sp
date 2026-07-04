* PSS fixture: half-wave rectifier under sine drive, nonlinear PSS.
Vin in 0 DC 0 SIN(0 5 1k)
D1 in out dm
.model dm D(is=1e-14)
R1 out 0 10k
C1 out 0 1u
.pss 1k 5m v(out) 256 8 100 1m
.end
