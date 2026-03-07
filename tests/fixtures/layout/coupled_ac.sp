Synthetic matched coupled RC routes: coupling cancels in common mode
* Expected results: coupled_ac.expected.json
* Origin: benchmark/fixtures/layout/coupled_ac/circuit.sp
Vin in 0 DC 0 AC 1
R0 in out0 1k
C0 out0 0 1n
R1 in out1 1k
C1 out1 0 1n
Cc1 out0 out1 20p
R2 in out2 1k
C2 out2 0 1n
Cc2 out1 out2 20p
R3 in out3 1k
C3 out3 0 1n
Cc3 out2 out3 20p
R4 in out4 1k
C4 out4 0 1n
Cc4 out3 out4 20p
R5 in out5 1k
C5 out5 0 1n
Cc5 out4 out5 20p
R6 in out6 1k
C6 out6 0 1n
Cc6 out5 out6 20p
R7 in out7 1k
C7 out7 0 1n
Cc7 out6 out7 20p
R8 in out8 1k
C8 out8 0 1n
Cc8 out7 out8 20p
R9 in out9 1k
C9 out9 0 1n
Cc9 out8 out9 20p
R10 in out10 1k
C10 out10 0 1n
Cc10 out9 out10 20p
R11 in out11 1k
C11 out11 0 1n
Cc11 out10 out11 20p
R12 in out12 1k
C12 out12 0 1n
Cc12 out11 out12 20p
R13 in out13 1k
C13 out13 0 1n
Cc13 out12 out13 20p
R14 in out14 1k
C14 out14 0 1n
Cc14 out13 out14 20p
R15 in out15 1k
C15 out15 0 1n
Cc15 out14 out15 20p
.ac dec 5 10 100meg
.end
