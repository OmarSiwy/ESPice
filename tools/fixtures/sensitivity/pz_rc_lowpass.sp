* Pole-Zero Analysis of First-Order RC Lowpass
*
* Single real pole at s = -1/(R*C) = -1/(1k*10n) = -1e8 rad/s
* f_pole = 1/(2*pi*R*C) ~ 15.9 kHz
* No zeros in this transfer function
* H(s) = 1/(1 + s*R*C)

V1 in 0 DC 0 AC 1
R1 in out 1k
C1 out 0 10n

.PZ in 0 out 0 VOL PZ

.END
