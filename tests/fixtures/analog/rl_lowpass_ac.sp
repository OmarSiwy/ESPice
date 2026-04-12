* First-Order RL Lowpass Filter - AC Sweep
*
* f_c = R/(2*pi*L) = 100/(2*pi*1m) ~ 15.9 kHz
*

V1 in 0 DC 0 AC 1
R1 in out 100
L1 out 0 1m

.AC DEC 20 10 10MEG

.END
