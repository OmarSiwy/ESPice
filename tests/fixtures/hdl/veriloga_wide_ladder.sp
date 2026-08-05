* A Verilog-A device past 64 unknowns (#117): 70 unknowns, a dense
* Jacobian and one derivative lane per unknown.
* Expected results: veriloga_wide_ladder.expected.json
* Oracle (analytic): 69 equal 1 kohm resistors in series across 69 V
* carry 1 mA, so n[k] sits at 69 - k V.
.hdl "veriloga_wide_ladder.assets/ladder70.va"
V1 in 0 DC 69
N1 in 0 ladder70
.op
.end
