* NPN BJT temperature dependence: Gummel plot at multiple temperatures.
* Expected results: device_bjt_npn_temp.expected.json
* Origin: benchmark/fixtures/devices/bjt_npn_temp/circuit.sp
* Tests IS(T), BF(T), and Vbe(T) temperature models.
Vce col 0 DC 5
Vbe base 0 DC 0
Q1 col base 0 QNPN
.model QNPN NPN(IS=1e-16 BF=150 NF=1 VAF=100 IKF=30m XTI=3 EG=1.11 XTB=1.5 RC=10 RB=50 RE=1)
.dc Vbe 0.3 0.85 0.005 TEMP -40 125 55
.end
