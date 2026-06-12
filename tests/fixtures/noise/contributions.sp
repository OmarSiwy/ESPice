* Per-device noise contributions: ngspice's .noise pts summary
* Oracle: ngspice 44.2 -b -r on this deck. With pts nonzero, ngspice
* writes one density per generator and per instance (onoise_<inst>_<gen>,
* onoise_<inst>) and their integrals (v(onoise_total_<inst>...)).
* Expected results: contributions.expected.json
Vin in 0 dc 1 ac 1
R1 in out 1k
R2 out 0 3k
C1 out 0 1n
D1 out 0 dmod
.model dmod d is=1e-14 rs=10
.noise v(out) Vin dec 2 1k 100k 1
.end
