* N-JFET output characteristics: Id vs Vds at multiple Vgs.
* Expected results: device_jfet_output.expected.json
* Origin: benchmark/fixtures/devices/jfet_output/circuit.sp
* Tests pinch-off, linear, and saturation regions.
Vds drain 0 DC 0
Vgs gate 0 DC 0
J1 drain gate 0 nj
.model nj NJF(VTO=-2 BETA=1m LAMBDA=2m RD=10 RS=10 CGS=2p CGD=1p IS=1e-14)
.dc Vds 0 10 0.05 Vgs -2 0 0.25
.end
