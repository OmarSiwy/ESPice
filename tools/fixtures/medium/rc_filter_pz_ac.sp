* M13: Two-Stage RC Lowpass — PZ and AC cross-check, two real poles
V1 in 0 DC 0 AC 1
R1 in mid 1k
C1 mid 0 1n
R2 mid out 1k
C2 out 0 1n
.AC DEC 20 1k 1G
.PZ V(out) V1 CUR POL
.END
