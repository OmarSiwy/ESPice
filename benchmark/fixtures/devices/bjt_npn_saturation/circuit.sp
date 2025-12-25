* NPN BJT deep saturation: both junctions forward-biased.
* Tests Vce(sat) and saturation current limiting.
Vce col 0 DC 0
Vbe base 0 DC 0.8
Q1 col base 0 QNPN
.model QNPN NPN(IS=1e-16 BF=100 BR=1 NF=1 NR=1 VAF=100 IKF=30m RC=10 RB=100 RE=1)
.dc Vce 0 0.5 0.002 Vbe 0.7 0.85 0.05
.end
