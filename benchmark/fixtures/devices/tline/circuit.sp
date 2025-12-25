* Unit fixture: ideal transmission line, matched pulse launch.
Vin in 0 DC 0 PULSE(0 1 1n 0.5n 0.5n 5n 20n)
Rs in a 50
T1 a 0 b 0 Z0=50 TD=2n
RL b 0 50
.tran 0.05n 30n
.end
