* Q08: Lossy Transmission Line Driver — LTRA model, R=5, L=250n, C=100p
V1 in 0 PULSE(0 1 0 0.1n 0.1n 5n 10n)
RS in n1 50
O1 n1 0 n2 0 LMOD
RL n2 0 75
.MODEL LMOD LTRA (R=5 L=250n C=100p LEN=0.5)
.TRAN 0.1n 20n
.END
