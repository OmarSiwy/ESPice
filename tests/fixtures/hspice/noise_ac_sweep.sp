* HSPICE .noise ov src inter [CR .NOISE]: the frequencies are the .ac
* card's, and a nonzero inter adds each device's contribution. Oracle:
* ngspice 44.2 on the same circuit with `.noise v(out) vin dec 2 1k 100k 1`
* (the equivalent ngspice card); TNOM and TEMP pinned to ngspice's 27 C.
* Expected results: noise_ac_sweep.expected.json
vin in 0 dc 1 ac 1
r1 in out 1k
r2 out 0 3k
c1 out 0 1n
d1 out 0 dmod
.model dmod d is=1e-14 rs=10
.option tnom=27
.temp 27
.ac dec 2 1k 100k
.noise v(out) vin 1
.end
