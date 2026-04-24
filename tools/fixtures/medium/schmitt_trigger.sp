* M03: BJT Schmitt Trigger — Hysteresis with two NPN transistors
VCC vcc 0 DC 5
VIN in 0 PULSE(0 5 0 10u 10u 50u 100u)
R1 vcc c1 10k
R2 c1 b2 10k
R3 vcc c2 10k
RE e 0 1k
Q1 c1 in e 0 NPN1
Q2 c2 b2 e 0 NPN1
.MODEL NPN1 NPN (BF=100 IS=1e-15 VAF=100 RB=10)
.TRAN 1u 200u
.END
