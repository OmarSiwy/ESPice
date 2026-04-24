* M08: Single Ideal Transmission Line — Z0=50, TD=2ns, mismatched load
V1 in 0 PULSE(0 1 0 0.1n 0.1n 5n 10n)
RS in n1 50
T1 n1 0 n2 0 Z0=50 TD=2n
RL n2 0 100
.TRAN 0.05n 25n
.END
