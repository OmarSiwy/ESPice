* N-MESFET output characteristics: Id vs Vds at multiple Vgs.
* Expected results: device_mesfet_output.expected.json
* Origin: benchmark/fixtures/devices/mesfet_output/circuit.sp
* Tests Schottky barrier FET physics.
Vds drain 0 DC 0
Vgs gate 0 DC 0
Z1 drain gate 0 nmf
.model nmf NMF(VTO=-1.5 BETA=2m ALPHA=2 LAMBDA=5m RD=10 RS=10 CGS=2p CGD=1p IS=1e-14)
.dc Vds 0 5 0.025 Vgs -1.5 0.5 0.25
.end
