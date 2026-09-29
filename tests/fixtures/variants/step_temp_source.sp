* Nested .step over a source and the temperature; the last card varies
* fastest. Oracle: ngspice 45, one run per point (the source value and
* .options temp= written into the deck).
* Expected results: step_temp_source.expected.json
v1 a 0 1
r1 a b 1k
d1 b 0 dmod
.model dmod d is=1e-14 n=1.1 rs=5
.step v1 list 1 2
.step temp list -40 85
.op
.end
