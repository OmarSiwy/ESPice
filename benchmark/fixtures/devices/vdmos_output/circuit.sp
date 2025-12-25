* VDMOS output characteristics: Id vs Vds at multiple Vgs.
* Tests power MOSFET physics.
Vds drain 0 DC 0
Vgs gate 0 DC 0
M1 drain gate 0 VMOD W=100u L=1u
.model VMOD VDMOS(VTO=3 KP=2 LAMBDA=0.02 RG=5 RD=0.1 RS=0.1 RB=0.1 CGDMAX=100p CGDMIN=10p CGS=50p A=1 IS=1e-14)
.dc Vds 0 20 0.1 Vgs 0 10 1
.end
