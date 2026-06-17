* HSPICE .acmatch, .dcsens and .dcmatch over a variation block: a diode
* biased through r1 (sigma 10%) with c1 (sigma 5%) across it. r1 moves the
* bias and with it the diode conductance, so the AC spread carries the
* operating-point shift; c1 moves only the AC response.
* Oracle: analytic (see the expected.json derivation).
* Expected results: match_diode.expected.json
vdd vdd 0 dc 2
r1 vdd d 1k
d1 d 0 dm
c1 d 0 1n
iac 0 d dc 0 ac 1
.model dm d is=1e-14 n=1
.option tnom=27
.temp 27
.variation
.element_variation
r r=10%
c c=5%
.end_element_variation
.end_variation
.ac dec 1 1k 1meg
.acmatch v(d)
.dcsens v(d)
.dcmatch v(d)
.end
