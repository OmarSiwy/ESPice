* Two-tone diode intermodulation against VACASK multi-tone HB
* Expected results: two_tone_diode_vacask.expected.json
V1 1 3 SIN(0.5 0.02 1k)
V2 3 0 SIN(0 0.02 1.3k)
R1 1 2 1k
D1 2 0 dm
.model dm D(is=1e-12)
.hb tones=1k 1.3k nharms=7 7 intmodmax=7
.end
