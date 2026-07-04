* VBIC NPN Gummel plot: Ic and Ib vs Vbe.
* Tests VBIC forward current gain across bias range.
Vce col 0 DC 3
Vbe base 0 DC 0
Q1 col base 0 0 vb1
.model vb1 NPN(LEVEL=4 IS=1e-16 BF=200 NF=1 NR=1 IKF=50m IKR=5m ISE=1e-13 NE=1.5 ISC=1e-15 NC=2 VAF=150 RBI=50 RCI=20 RE=1)
.dc Vbe 0.2 0.9 0.005
.end
