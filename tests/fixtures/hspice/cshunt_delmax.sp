* .option cshunt adds a capacitance from every node to ground and delmax
* caps the transient step [CR Ch.3]. Oracle: analytic, a 1 mA step into
* 1k || 1 nF: 1 - exp(-t / 1 us) V.
* Expected results: cshunt_delmax.expected.json
.option cshunt=1n delmax=50n
i1 0 a pwl(0 0 1p 1m)
r1 a 0 1k
.tran 1u 8u
.end
