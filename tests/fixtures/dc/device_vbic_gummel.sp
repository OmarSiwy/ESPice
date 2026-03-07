* VBIC NPN Gummel plot: Ic and Ib vs Vbe.
* Expected results: device_vbic_gummel.expected.json
* Origin: benchmark/fixtures/devices/vbic_gummel/circuit.sp
* Tests VBIC forward current gain across bias range.
Vce col 0 DC 3
Vbe base 0 DC 0
Q1 col base 0 0 vb1
.model vb1 NPN(LEVEL=4 IS=1e-16  NF=1 NR=1 IKF=50m IKR=5m      RBI=50 RCI=20 RE=1)
.dc Vbe 0.2 0.9 0.005
.end
