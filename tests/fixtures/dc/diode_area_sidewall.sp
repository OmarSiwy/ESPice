* Diode geometry and sidewall terms (#79), against ngspice 45:
*   D1 positional area 4             D2 area=2.5 pj=1e-3, JSW merged into IS
*   D3 JSW with NS (own sidewall diode) and IKR in reverse
*   D4 LEVEL=3 with W/L/XW: AREA and PJ from the drawing, IBV scaled by area
*   D5 instance temp=80              D6 dtemp=-30
VA a 0 0
D1 a 0 dm 4
D2 a 0 dm area=2.5 pj=1e-3
D3 a 0 dsw area=2 pj=4e-4
D4 a 0 dl3 w=20u l=10u
D5 a 0 dm temp=80
D6 a 0 dm dtemp=-30
.model dm D IS=1e-14 RS=2 JSW=1e-12 N=1.05 IKF=10m
.model dsw D IS=1e-14 RS=2 JSW=1e-11 NS=1.4 IKR=1u BV=6 IBV=1u
.model dl3 D LEVEL=3 IS=1e-4 JSW=1e-10 RS=1e-9 XW=1u BV=8 IBV=1e-1
.dc VA -9 0.8 0.05
.end
