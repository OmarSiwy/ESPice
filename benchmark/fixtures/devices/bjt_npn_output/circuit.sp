* NPN BJT output characteristics: Ic vs Vce at multiple Ib.
* Sweeps all regions: cutoff, active, saturation.
Vce col 0 DC 0
Vbe base 0 DC 0.7
Q1 col base 0 QNPN
.model QNPN NPN(IS=1e-16 BF=100 BR=1 NF=1 NR=1 VAF=100 VAR=20 IKF=10m IKR=10m RC=10 RB=100 RE=1)
.dc Vce 0 10 0.05 Vbe 0.6 0.8 0.025
.end
