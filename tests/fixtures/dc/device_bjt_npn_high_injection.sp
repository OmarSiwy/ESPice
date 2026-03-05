* NPN BJT high injection effects: IKF knee rolloff.
* Expected results: device_bjt_npn_high_injection.expected.json
* Origin: benchmark/fixtures/devices/bjt_npn_high_injection/circuit.sp
* Large Vbe sweep to observe BF degradation at high current.
Vce col 0 DC 3
Vbe base 0 DC 0
Q1 col base 0 QNPN
.model QNPN NPN(IS=1e-16 BF=200 NF=1 IKF=10m ISE=1e-13 NE=1.5 VAF=100 RC=5 RB=30 RE=0.5)
.dc Vbe 0.5 0.95 0.002
.end
