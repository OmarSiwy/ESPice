* HSPICE .acmatch and .dcmatch over a model variation on the diode IS
* (#85): hspice/match_diode's circuit with IS = 1e-14 at sigma 10%. The
* finite-difference step on IS must stay relative (1e-6 IS), or the bias
* shift is extrapolated over a 100x jump in IS and the column flips sign.
* Oracle: analytic (see the expected.json derivation).
* Expected results: match_diode_is.expected.json
vdd vdd 0 dc 2
r1 vdd d 1k
d1 d 0 dm
c1 d 0 1n
iac 0 d dc 0 ac 1
.model dm d is=1e-14 n=1
.option tnom=27
.temp 27
.variation
.local_variation
d dm is=10%
.end_local_variation
.end_variation
.ac dec 1 1k 1meg
.acmatch v(d)
.dcmatch v(d)
.end
