* PNP BJT operating point in active region.
* Expected results: device_bjt_pnp.expected.json
* Origin: benchmark/fixtures/devices/bjt_pnp/circuit.sp
Vcc 0 c DC 5
Vbb 0 b DC 0.7
RC col c 1k
RB base b 10k
Q1 col base 0 QPNP
.model QPNP PNP(IS=1e-16 BF=80 NF=1 VAF=80 RC=10 RB=100 RE=1)
.op
.end
