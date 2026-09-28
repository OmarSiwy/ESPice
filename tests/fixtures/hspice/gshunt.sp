* .option gshunt adds a conductance from every node to ground [CR Ch.3];
* ignoring it left the answer unmoved. Oracle: analytic, 1 mA into
* 1k || 1 mS = 0.5 V.
* Expected results: gshunt.expected.json
.option gshunt=1m gmindc=1e-12 absv=1e-6 relv=1e-3 absi=1e-12 method=bdf post
i1 0 a 1m
r1 a 0 1k
.op
.end
