* BSIM3v3 NMOS temperature dependence: transfer curve at multiple temps.
Vds drain 0 DC 0.9
Vgs gate 0 DC 0
M1 drain gate 0 0 n3 W=10u L=0.18u
.model n3 NMOS(LEVEL=49 VERSION=3.3 TNOM=27 TOX=4.1e-9 VTH0=0.35 K1=0.53 K2=-0.06 VSAT=1.5e5 U0=280 UA=-1.4e-9 UB=2.3e-18 UC=-4.6e-11 RDSW=200 AT=3.3e4 UTE=-1.5 KT1=-0.11 KT1L=0 KT2=0.022 PRT=0)
.dc Vgs 0 1.8 0.005 TEMP -40 125 55
.end
