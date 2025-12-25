* HB guard fixture: tline has no time-domain form — the driver must still
* compile (comptime gate, no Hb instantiation) and report hb skipped.
Vin in 0 DC 0 SIN(0 1 1k)
RS in a 50
T1 a 0 b 0 Z0=50 TD=1n
RL b 0 50
.op
.hb 1k
.end
