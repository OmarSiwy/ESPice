* Second-Order Sallen-Key Lowpass Filter
*
* Unity-gain buffer approximated by VCVS (E source, gain=1)
* R1=R2=1k, C1=C2=10n
* f_0 = 1/(2*pi*R*C) ~ 15.9 kHz, Butterworth (Q=0.707)
*

V1 in 0 DC 0 AC 1
R1 in n1 1k
R2 n1 n2 1k
C1 n1 out 10n
C2 n2 0 10n
E1 out 0 n2 0 1

.AC DEC 20 100 100MEG

.END
