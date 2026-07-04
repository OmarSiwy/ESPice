* BSIM3v3 NMOS body effect: transfer curve at multiple Vbs.
Vds drain 0 DC 0.9
Vgs gate 0 DC 0
Vbs bulk 0 DC 0
M1 drain gate 0 bulk n3 W=10u L=0.18u
.model n3 NMOS(LEVEL=49 VERSION=3.3 TNOM=27 TOX=4.1e-9 VTH0=0.35 K1=0.53 K2=-0.06 K3=80 VSAT=1.5e5 U0=280 RDSW=200)
.dc Vgs 0 1.8 0.005 Vbs -1.8 0 0.6
.end
