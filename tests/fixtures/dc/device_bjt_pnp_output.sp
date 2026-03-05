* PNP BJT output characteristics: Ic vs Vec at multiple Veb.
* Expected results: device_bjt_pnp_output.expected.json
* Origin: benchmark/fixtures/devices/bjt_pnp_output/circuit.sp
* Sweeps all regions with PNP polarity conventions.
Vec 0 col DC 0
Veb 0 base DC 0.7
Q1 col base 0 QPNP
.model QPNP PNP(IS=1e-16 BF=80 BR=1 NF=1 NR=1 VAF=80 VAR=15 IKF=8m IKR=5m RC=10 RB=100 RE=1)
.dc Vec 0 10 0.05 Veb 0.6 0.8 0.025
.end
