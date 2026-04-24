* Pole-Zero Analysis of Sallen-Key Lowpass Filter (Unity Gain)
*
* Second-order active lowpass filter
* R1=R2=1k, C1=C2=10n => f0 = 1/(2*pi*R*C) ~ 15.9 kHz
* Unity-gain buffer (E1 gain=1) gives Butterworth response (Q=0.5 for equal components)
* Two poles, no finite zeros

V1 in 0 DC 0 AC 1
R1 in n1 1k
R2 n1 n2 1k
C1 n1 out 10n
C2 n2 0 10n
E1 out 0 n2 0 1

.PZ in 0 out 0 VOL PZ

.END
