Independent source waveforms
* Each source drives its own 1k load, so every node shows its waveform.
VP p 0 PULSE(0 1 1m 0.1m 0.1m 2m 5m)
VS s 0 SIN(0.5 0.5 1k)
VW w 0 PWL(0 0 1m 1 3m 1 4m 0)
VE e 0 EXP(0 1 1m 0.5m 3m 0.5m)
IC 0 c DC 1m
RP p 0 1k
RS s 0 1k
RW w 0 1k
RE e 0 1k
RC c 0 1k
.tran 10u 5m
.end
