* Unit fixture: voltage-controlled switch with hysteresis, ramp control.
Vc ctl 0 PWL(0 0 10m 5 20m 0)
Vs in 0 DC 10
S1 in out ctl 0 sw1
RL out 0 1k
.model sw1 SW(vt=2.5 vh=0.5 ron=1 roff=1meg)
.tran 0.1m 20m
.end
