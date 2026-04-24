* Series RLC Bandpass Filter - AC Sweep
*
* f_0 = 1/(2*pi*sqrt(L*C)) = 1/(2*pi*sqrt(100u*10n)) ~ 159 kHz
* Q = (1/R)*sqrt(L/C)
*

V1 in 0 DC 0 AC 1
R1 in n1 50
L1 n1 out 100u
C1 out 0 10n
R2 out 0 10k

.AC DEC 20 1k 10MEG

.END
