* MESA transistor output characteristics: Id vs Vds at multiple Vgs.
* Expected results: device_mesa_output.expected.json
* Origin: benchmark/fixtures/devices/mesa_output/circuit.sp
* Tests MESA-etched FET physics at level 2 and 3.
Vds drain 0 DC 0
Vgs gate 0 DC 0
Z1 drain gate 0 nmesa
.model nmesa NMF(LEVEL=2 VTO=-1.5 BETA=2m ALPHA=2 LAMBDA=5m RD=10 RS=10)
.dc Vds 0 5 0.025 Vgs -1.5 0.5 0.25
.end
