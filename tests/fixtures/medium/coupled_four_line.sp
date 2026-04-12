* M10: Four Coupled Transmission Lines — capacitive coupling between adjacent lines
V1 in1 0 PULSE(0 1 0 0.1n 0.1n 5n 10n)
RS1 in1 n1 50
RS2 0 n2 50
RS3 0 n3 50
RS4 0 n4 50
T1 n1 0 n5 0 Z0=50 TD=1n
T2 n2 0 n6 0 Z0=50 TD=1n
T3 n3 0 n7 0 Z0=50 TD=1n
T4 n4 0 n8 0 Z0=50 TD=1n
C12 n1 n2 0.2p
C23 n2 n3 0.2p
C34 n3 n4 0.2p
RL1 n5 0 50
RL2 n6 0 50
RL3 n7 0 50
RL4 n8 0 50
.TRAN 0.05n 20n
.END
