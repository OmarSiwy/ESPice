* N-JFET transfer characteristics: Id vs Vgs at fixed Vds.
* Expected results: device_jfet_transfer.expected.json
* Origin: benchmark/fixtures/devices/jfet_transfer/circuit.sp
* Tests pinch-off voltage and transconductance.
Vds drain 0 DC 5
Vgs gate 0 DC 0
J1 drain gate 0 nj
.model nj NJF(VTO=-2 BETA=1m LAMBDA=2m RD=10 RS=10 IS=1e-14)
.dc Vgs -3 0.5 0.01
.end
