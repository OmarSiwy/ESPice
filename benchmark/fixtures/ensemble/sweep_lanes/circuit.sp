* Ensemble sweep-as-lanes fixture: diode I-V sweep, each sweep point a lane.
Vin in 0 DC 0
R1 in out 100
D1 out 0 dm
.model dm D(is=1e-14 n=1.2)
.dc Vin 0 1.6 0.025
.end
