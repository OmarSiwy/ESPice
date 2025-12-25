* Single-stage RC buffer driven by a logic pulse; rise/fall time check.
Vin in 0 DC 0 PULSE(0 3.3 0 100p 100p 10n 20n)
R1 in out 500
C1 out 0 20p
.tran 0.1n 60n
.end
