* HSPICE .pz ov src [CR .PZ]: the input is the named source's node pair
* (vol for a V card), and poles and zeros are both found. Oracle:
* ngspice 44.2 on the same circuit with `.pz in 0 out 0 vol pz`.
* Expected results: pz_source.expected.json
vin in 0 dc 0 ac 1
r1 in a 1k
c1 a 0 1n
r2 a out 2k
c2 out 0 0.5n
cz in out 0.1n
.pz v(out) vin
.end
