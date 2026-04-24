* Series LC Notch (Band-Reject) Filter - AC Sweep
*
* Series LC to ground creates a notch at resonance
* f_0 = 1/(2*pi*sqrt(L*C)) = 1/(2*pi*sqrt(100u*10n)) ~ 159 kHz
*

V1 in 0 DC 0 AC 1
R1 in out 1k
L1 out n1 100u
C1 n1 0 10n

.AC DEC 20 1k 10MEG

.END
