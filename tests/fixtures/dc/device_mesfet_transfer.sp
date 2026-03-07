* N-MESFET transfer characteristics: Id vs Vgs at fixed Vds.
* Expected results: device_mesfet_transfer.expected.json
* Origin: benchmark/fixtures/devices/mesfet_transfer/circuit.sp
Vds drain 0 DC 3
Vgs gate 0 DC 0
Z1 drain gate 0 nmf
.model nmf NMF(VTO=-1.5 BETA=2m ALPHA=2 LAMBDA=5m RD=10 RS=10 IS=1e-14)
.dc Vgs -2 0.5 0.01
.end
