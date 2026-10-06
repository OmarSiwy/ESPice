RC low-pass filter
* 1 kOhm and 159 nF: the corner is near 1 kHz.
V1 in 0 DC 0 AC 1 PULSE(0 1 0 1u 1u 5m 10m)
R1 in out 1k
C1 out 0 159n
.op
.ac dec 10 10 100k
.tran 10u 5m
.end
