* M01: RC Baseline — Simple RC, linear baseline with TRAN and AC
V1 in 0 PULSE(0 1 0 1n 1n 5u 10u)
R1 in out 1k
C1 out 0 1n
.TRAN 1n 10u
.AC DEC 20 1k 1G
.END
