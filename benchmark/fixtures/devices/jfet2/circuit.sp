* N-JFET Level 2 (Parker-Skellern) output and transfer.
Vds drain 0 DC 0
Vgs gate 0 DC 0
J1 drain gate 0 nj2
.model nj2 NJF(LEVEL=2 VTO=-2 BETA=1m LAMBDA=2m RD=10 RS=10 IS=1e-14)
.dc Vds 0 10 0.05 Vgs -2 0 0.25
.end
