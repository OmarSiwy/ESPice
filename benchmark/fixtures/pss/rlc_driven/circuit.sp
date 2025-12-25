* PSS fixture: driven series RLC settles to periodic steady state.
Vin in 0 DC 0 SIN(0 1 10k)
R1 in n1 50
L1 n1 out 1m
C1 out 0 100n
.pss 10k 1m v(out) 256 4 50 1m
.end
