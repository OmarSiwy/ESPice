* NMOS Level 2 transfer characteristics: Ids vs Vgs.
Vds drain 0 DC 3
Vgs gate 0 DC 0
M1 drain gate 0 0 NMOD W=10u L=1u
.model NMOD NMOS(LEVEL=2 VTO=0.7 KP=120u GAMMA=0.4 PHI=0.65 LAMBDA=0.04 UCRIT=1e4 UEXP=0.1 NEFF=1 TOX=40n)
.dc Vgs 0 5 0.01
.end
