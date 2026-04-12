* AC Sensitivity of RC Lowpass Filter
*
* First-order RC lowpass: f_3dB = 1/(2*pi*R*C) ~ 15.9kHz
* AC sensitivity shows how output magnitude/phase
* change with respect to each component vs frequency

V1 in 0 DC 0 AC 1
R1 in out 1k
C1 out 0 10n

.AC DEC 10 1k 100MEG
.SENS V(out)

.END
