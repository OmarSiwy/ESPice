* First-Order RC Lowpass Filter - AC Sweep
*
* f_c = 1/(2*pi*R*C) = 1/(2*pi*1k*10n) ~ 15.9 kHz
*

V1 in 0 DC 0 AC 1
R1 in out 1k
C1 out 0 10n

.AC DEC 20 100 100MEG

.END
