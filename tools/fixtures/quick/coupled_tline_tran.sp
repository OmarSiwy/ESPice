* Q07: Coupled Transmission Line with Pulse — Z0=50, TD=1ns
V1 in 0 PULSE(0 1 0 0.1n 0.1n 5n 10n)
RS in n1 50
T1 n1 0 n2 0 Z0=50 TD=1n
RL n2 0 50
.TRAN 0.05n 20n
.END
