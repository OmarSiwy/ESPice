* Half-wave rectifier with smoothing capacitor and load.
Vac in 0 DC 0 SIN(0 10 1k)
D1 in out DR
C1 out 0 47u
Rload out 0 1k
.model DR D(IS=1e-12 N=1)
.tran 10u 5m
.end
