* M02: NMOS Differential Pair — Full OP/AC/TRAN analysis
VDD vdd 0 DC 3.3
VPLUS inp 0 DC 1.65 AC 1
VMINUS inn 0 DC 1.65
ISS tail 0 DC 200u
M1 outp inp tail 0 NMOD W=10u L=1u
M2 outn inn tail 0 NMOD W=10u L=1u
RD1 vdd outp 10k
RD2 vdd outn 10k
.MODEL NMOD NMOS (VTO=0.5 KP=120u GAMMA=0.4 PHI=0.65 LAMBDA=0.04)
.OP
.AC DEC 20 100 1G
.TRAN 1n 1u
.END
