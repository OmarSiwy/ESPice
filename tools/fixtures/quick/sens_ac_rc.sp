* Q05: AC Sensitivity of RC Lowpass — V(out)/V(in) = 1/(1 + j*w*RC)
V1 in 0 DC 0 AC 1
R1 in out 1k
C1 out 0 10n
.AC DEC 10 1k 100MEG
.SENS V(out)
.END
