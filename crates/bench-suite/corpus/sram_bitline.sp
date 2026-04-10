* SRAM bitline discharge model — long RC line
Vbl bl 0 1.0
R1 bl n1 100
C1 n1 0 10f
R2 n1 n2 100
C2 n2 0 10f
R3 n2 n3 100
C3 n3 0 10f
R4 n3 n4 100
C4 n4 0 10f
R5 n4 n5 100
C5 n5 0 10f
R6 n5 n6 100
C6 n6 0 10f
R7 n6 n7 100
C7 n7 0 10f
R8 n7 out 100
Cload out 0 50f
.tran 1p 1n
.end
