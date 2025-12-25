* NPN BJT Gummel plot: Ic and Ib vs Vbe.
* Tests forward current gain, leakage, high-injection (ISE, ISC, IKF).
Vce col 0 DC 5
Vbe base 0 DC 0
Q1 col base 0 QNPN
.model QNPN NPN(IS=1e-16 BF=200 NF=1 ISE=1e-13 NE=1.5 BR=5 NR=1 ISC=1e-15 NC=2 IKF=50m IKR=5m VAF=150 RC=10 RB=50 RE=1)
.dc Vbe 0.2 0.9 0.005
.end
