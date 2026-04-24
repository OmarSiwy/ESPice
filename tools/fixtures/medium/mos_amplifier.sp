* M04: NMOS Common-Source Amplifier — OP and AC analysis
VDD vdd 0 DC 5
VIN in 0 DC 1.5 AC 1
RD vdd out 5k
RS s 0 1k
CS s 0 10u
M1 out in s 0 NMOD W=20u L=1u
.MODEL NMOD NMOS (VTO=0.7 KP=110u GAMMA=0.4 PHI=0.65 LAMBDA=0.04)
.OP
.AC DEC 20 10 1G
.END
