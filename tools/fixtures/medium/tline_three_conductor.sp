* M09: Three Parallel Transmission Lines — with capacitive coupling
V1 in1 0 PULSE(0 1 0 0.1n 0.1n 5n 10n)
V2 in2 0 DC 0
V3 in3 0 DC 0
RS1 in1 n1 50
RS2 in2 n2 50
RS3 in3 n3 50
T1 n1 0 n4 0 Z0=50 TD=1n
T2 n2 0 n5 0 Z0=50 TD=1n
T3 n3 0 n6 0 Z0=50 TD=1n
C12 n1 n2 0.1p
C23 n2 n3 0.1p
RL1 n4 0 50
RL2 n5 0 50
RL3 n6 0 50
.TRAN 0.05n 20n
.END
