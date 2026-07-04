* TF fixture: three-section resistive ladder, gain and port resistances.
Vin in 0 DC 9 AC 1
R1 in n1 1k
R2 n1 0 2k
R3 n1 n2 1k
R4 n2 0 2k
R5 n2 out 1k
R6 out 0 2k
.tf V(out) Vin
.end
