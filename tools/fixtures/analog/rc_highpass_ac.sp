* First-Order RC Highpass Filter - AC Sweep
*
* f_c = 1/(2*pi*R*C) = 1/(2*pi*1k*10n) ~ 15.9 kHz
*

V1 in 0 DC 0 AC 1
C1 in out 10n
R1 out 0 1k

.AC DEC 20 100 100MEG

.END
