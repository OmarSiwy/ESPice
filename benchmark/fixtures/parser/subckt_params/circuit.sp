* Subcircuit with parameterized values, instantiated twice (flatten test).
.subckt rcfilter a b r=1k c=1n
R1 a mid {r}
C1 mid b {c}
.ends
X1 in mid1 rcfilter r=2k c=2n
X2 mid1 out rcfilter r=4k c=1n
Vin in 0 DC 0 PULSE(0 1 0 1n 1n 50u 100u)
Rl out 0 1meg
.tran 1u 0.2m
.end
