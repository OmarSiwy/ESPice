* Series-terminated line with reflection at an under-damped load.
Vin in 0 DC 0 PULSE(0 3.3 0 100p 100p 4n 8n)
RS in a 25
T1 a 0 b 0 Z0=50 TD=1.5n
RL b 0 200
.tran 25p 16n
.end
