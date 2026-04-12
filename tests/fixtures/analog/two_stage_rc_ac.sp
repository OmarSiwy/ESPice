* Cascaded Two-Stage RC Lowpass Filter - AC Sweep
*
* Two poles, each at f_c ~ 15.9 kHz
* -40 dB/decade rolloff above both poles
*

V1 in 0 DC 0 AC 1
R1 in mid 1k
C1 mid 0 10n
R2 mid out 1k
C2 out 0 10n

.AC DEC 20 100 100MEG

.END
