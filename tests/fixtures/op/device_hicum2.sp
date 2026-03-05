* HICUM/L2 NPN DC operating point.
* Expected results: device_hicum2.expected.json
* Origin: benchmark/fixtures/devices/hicum2/circuit.sp
* ngspice: Q device with level=8 (HICUM/L2 v2.4+).
Vcc vcc 0 DC 3.3
Vb b 0 DC 0.85
Rc vcc c 500
Q1 c b 0 0 hic2
.model hic2 NPN(LEVEL=8 TNOM=300.15 C10=2e-30 QP0=2e-14 IBEIS=1e-18 MBEI=1 IBCIS=1e-16 MBCI=1 RBI0=50 RBX=20 RE=2 RCX=10)
.op
.end
