* BSIM2 (Level 5) NMOS output and transfer characteristics.
Vds drain 0 DC 0
Vgs gate 0 DC 0
M1 drain gate 0 0 NMOD W=10u L=1u
.model NMOD NMOS(LEVEL=5 VFB=-0.3 PHI=0.65 K1=0.5 K2=-0.1 ETA0=0.02 MU0=600 U0H=0.05 TOX=40n DL=0 DW=0)
.dc Vds 0 5 0.025 Vgs 0 5 0.5
.end
