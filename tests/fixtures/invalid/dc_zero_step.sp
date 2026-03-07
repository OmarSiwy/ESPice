* Zero DC step cannot advance the sweep.
* Expected results: dc_zero_step.expected.json
Vin in 0 1
R1 in out 1k
R2 out 0 1k
.dc Vin 0 1 0
.end
