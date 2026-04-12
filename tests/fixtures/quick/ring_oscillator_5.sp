* Q10: 5-Stage Ring Oscillator — Level 1 CMOS, VDD=3.3V
VDD vdd 0 DC 3.3
VPULSE kick n1 0 PULSE(0 3.3 0 0.1n 0.1n 1n 1e9)
M1n n2 n1 0 0 NMOD W=10u L=1u
M1p n2 n1 vdd vdd PMOD W=20u L=1u
M2n n3 n2 0 0 NMOD W=10u L=1u
M2p n3 n2 vdd vdd PMOD W=20u L=1u
M3n n4 n3 0 0 NMOD W=10u L=1u
M3p n4 n3 vdd vdd PMOD W=20u L=1u
M4n n5 n4 0 0 NMOD W=10u L=1u
M4p n5 n4 vdd vdd PMOD W=20u L=1u
M5n n1 n5 0 0 NMOD W=10u L=1u
M5p n1 n5 vdd vdd PMOD W=20u L=1u
C1 n1 0 0.01p
C2 n2 0 0.01p
C3 n3 0 0.01p
C4 n4 0 0.01p
C5 n5 0 0.01p
.MODEL NMOD NMOS (VTO=0.5 KP=120u GAMMA=0.4 PHI=0.65 LAMBDA=0.04 TOX=1e-7)
.MODEL PMOD PMOS (VTO=-0.5 KP=60u GAMMA=0.4 PHI=0.65 LAMBDA=0.05 TOX=1e-7)
.TRAN 0.01n 20n
.END
