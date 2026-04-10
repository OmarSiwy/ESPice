* NMOS Current Mirror — Iout ~= Iref * (W2/L2)/(W1/L1) = Iref
VDD 1 0 DC 3.3
IREF 1 2 DC 100u
M1 2 2 0 0 NMOD W=10u L=1u
M2 3 2 0 0 NMOD W=10u L=1u
R1 1 3 10k
.MODEL NMOD NMOS (VTO=0.5 KP=120u)
.OP
.END
