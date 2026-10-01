* SUBHARMS=2 puts lines at multiples of f/2: a 500 Hz drive under a 1 kHz tone
* Expected results: subharms_cubic.expected.json
V1 a 0 SIN(0 1 500)
Bout out 0 V=V(a)^3
Rload out 0 1k
.hb tones=1k nharms=2 subharms=2
.end
