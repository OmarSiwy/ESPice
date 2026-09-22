* NPN BJT Early effect: output resistance in active region.
* Expected results: device_bjt_npn_early.expected.json
* Origin: benchmark/fixtures/devices/bjt_npn_early/circuit.sp
* Tests VAF (forward Early voltage) and VAR (reverse Early voltage).
Vce col 0 DC 0
Vbe base 0 DC 0.7
Q1 col base 0 QNPN
.model QNPN NPN(IS=1e-16 BF=150 NF=1 VAF=50 VAR=10 RC=5 RB=50 RE=0.5)
.dc Vce 0 10 0.02 Vbe 0.65 0.75 0.05
.end
