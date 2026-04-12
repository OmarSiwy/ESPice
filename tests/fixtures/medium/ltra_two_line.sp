* M07: Two Cascaded Lossy Transmission Lines — LTRA model
V1 in 0 PULSE(0 1 0 0.1n 0.1n 5n 10n)
RS in n1 50
O1 n1 0 n2 0 LMOD
O2 n2 0 n3 0 LMOD
RL n3 0 50
.MODEL LMOD LTRA (R=5 L=250n C=100p LEN=1)
.TRAN 0.1n 30n
.END
