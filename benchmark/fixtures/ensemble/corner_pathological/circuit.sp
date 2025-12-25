* Ensemble lane-peeling target: one corner drives the diode into a
* near-vertical high-current region (tiny series R) where Newton struggles —
* the pathological lane must peel to the scalar path, not stall the batch.
Vin in 0 DC 12
R1 in out 0.1
D1 out 0 dm
.model dm D(is=1e-12 n=1.0)
.op
.end
