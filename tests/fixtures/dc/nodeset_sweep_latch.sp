* DC sweep starts from the .nodeset state of a bistable latch
* Expected results: nodeset_sweep_latch.expected.json
* x = y = 0 solves the latch exactly, so a cold sweep that ignores the
* nodeset reports that metastable point; ngspice applies the nodeset in the
* first point's MODEINITJCT/INITFIX iterations and stays on the x > 0 branch.
Vin in 0 0
B1 x 0 V=-tanh(3*(v(y)+v(in)))
B2 y 0 V=-tanh(3*v(x))
R1 x 0 1k
R2 y 0 1k
.nodeset v(x)=1 v(y)=-1
.dc Vin 0 0.2 0.05
.end
