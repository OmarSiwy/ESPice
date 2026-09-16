* HICUM/L2 NPN output characteristics: Ic vs Vce at multiple Vbe.
* Expected results: device_hicum2_output.expected.json
* Origin: benchmark/fixtures/devices/hicum2_output/circuit.sp
* Tests HICUM transfer current, Early effect, high-injection.
Vce col 0 DC 0
Vbe base 0 DC 0.8
Q1 col base 0 0 hic2
.model hic2 NPN(LEVEL=8 TNOM=300.15 C10=2e-30 QP0=2e-14 ICH=0 IBEIS=1e-18 MBEI=1 IREIS=0 MREI=2 IBCIS=1e-16 MBCI=1 RBI0=50 RBX=20 RE=2 RCX=10)
.dc Vce 0 5 0.025 Vbe 0.7 0.9 0.025
.end
