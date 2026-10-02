* An option card out of range is rejected, and the diagnostic names its line.
* Expected results: options_negative_reltol.expected.json
Vin in 0 1
R1 in out 1k
R2 out 0 1k
.options reltol=-1e-3
.op
.end
