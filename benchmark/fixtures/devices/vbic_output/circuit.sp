* VBIC NPN output characteristics: Ic vs Vce at multiple Vbe.
* Tests VBIC (level 4) model with enhanced Early effect and parasitic PNP.
Vce col 0 DC 0
Vbe base 0 DC 0.7
Q1 col base 0 0 vb1
.model vb1 NPN(LEVEL=4 IS=1e-16 BF=150 NF=1 NR=1 IKF=30m IKR=5m VAF=120 VAR=20 RBI=50 RCI=20 RE=1 RBX=10 RCX=5)
.dc Vce 0 5 0.025 Vbe 0.6 0.8 0.025
.end
