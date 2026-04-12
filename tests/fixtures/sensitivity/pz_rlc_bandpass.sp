* Pole-Zero Analysis of RLC Bandpass Filter
*
* Series RLC with output across capacitor forms bandpass
* Resonant frequency: f0 = 1/(2*pi*sqrt(L*C)) = 1/(2*pi*sqrt(100u*10n)) ~ 159 kHz
* Q = (1/R)*sqrt(L/C) = (1/50)*sqrt(100u/10n) = 2
* Two complex conjugate poles, one zero at origin

V1 in 0 DC 0 AC 1
R1 in mid 50
L1 mid out 100u
C1 out 0 10n
R2 out 0 10k

.PZ in 0 out 0 VOL PZ

.END
