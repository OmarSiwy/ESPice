* BSIM3v3 NMOS output characteristics: Ids vs Vds family.
* Tests DIBL, CLM, velocity saturation, mobility degradation.
Vds drain 0 DC 0
Vgs gate 0 DC 0
M1 drain gate 0 0 n3 W=10u L=0.18u
.model n3 NMOS(LEVEL=49 VERSION=3.3 TNOM=27 TOX=4.1e-9 VTH0=0.35 K1=0.53 K2=-0.06 K3=80 DVT0=0 DVT1=0 DVT2=0 NLEV=0 NLX=1.74e-7 W0=0 K3B=0.6 VSAT=1.5e5 UA=-1.4e-9 UB=2.3e-18 UC=-4.6e-11 RDSW=200 U0=280 PCLM=1.3 PDIBLC1=0.39 PDIBLC2=0.0086 DROUT=0.56 PSCBE1=4.24e8 PSCBE2=1e-5 PVAG=0.1 DELTA=0.01 ALPHA0=0 BETA0=30)
.dc Vds 0 1.8 0.01 Vgs 0 1.8 0.3
.end
