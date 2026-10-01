* HSPICE .measure DCMATCH and ACMATCH [CR .MEASURE] over hspice/match_diode:
* a bare FIND reads the one-row DC Mismatch plot, FIND ... AT the AC
* Mismatch sweep. Oracle: analytic, match_diode's derivation.
* Expected results: meas_match.expected.json
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
.measure dcmatch s3 find total_3sigma
.measure dcmatch sr1 find r1@r
.measure acmatch am find acm_mag at=1k
.measure acmatch ap find acm_phase at=1meg
.end
