* Ring Oscillator — 11 stages
VDD vdd 0 DC 3.3

.MODEL NMOD NMOS (VTO=0.5 KP=120u)
.MODEL PMOD PMOS (VTO=-0.5 KP=60u)

VKICK kick 0 PULSE(0 3.3 0 0.1n 0.1n 0.5n 100n)
RKICK kick n1 10k

Mn1 n2 n1 0 0 NMOD W=10u L=1u
Mp1 n2 n1 vdd vdd PMOD W=20u L=1u
CL1 n2 0 0.01p
Mn2 n3 n2 0 0 NMOD W=10u L=1u
Mp2 n3 n2 vdd vdd PMOD W=20u L=1u
CL2 n3 0 0.01p
Mn3 n4 n3 0 0 NMOD W=10u L=1u
Mp3 n4 n3 vdd vdd PMOD W=20u L=1u
CL3 n4 0 0.01p
Mn4 n5 n4 0 0 NMOD W=10u L=1u
Mp4 n5 n4 vdd vdd PMOD W=20u L=1u
CL4 n5 0 0.01p
Mn5 n6 n5 0 0 NMOD W=10u L=1u
Mp5 n6 n5 vdd vdd PMOD W=20u L=1u
CL5 n6 0 0.01p
Mn6 n7 n6 0 0 NMOD W=10u L=1u
Mp6 n7 n6 vdd vdd PMOD W=20u L=1u
CL6 n7 0 0.01p
Mn7 n8 n7 0 0 NMOD W=10u L=1u
Mp7 n8 n7 vdd vdd PMOD W=20u L=1u
CL7 n8 0 0.01p
Mn8 n9 n8 0 0 NMOD W=10u L=1u
Mp8 n9 n8 vdd vdd PMOD W=20u L=1u
CL8 n9 0 0.01p
Mn9 n10 n9 0 0 NMOD W=10u L=1u
Mp9 n10 n9 vdd vdd PMOD W=20u L=1u
CL9 n10 0 0.01p
Mn10 n11 n10 0 0 NMOD W=10u L=1u
Mp10 n11 n10 vdd vdd PMOD W=20u L=1u
CL10 n11 0 0.01p
Mn11 n1 n11 0 0 NMOD W=10u L=1u
Mp11 n1 n11 vdd vdd PMOD W=20u L=1u
CL11 n1 0 0.01p

.TRAN 0.01n 50n
.END
