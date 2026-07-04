* SUBHARMS with two tones: two subharmonic steps of the lowest tone are one order
* Expected results: subharms_two_tone_square.expected.json
V1 a 0 SIN(0 1 500)
V2 b 0 SIN(0 .5 1.3k)
Bout out 0 V=(V(a)+V(b))^2
Rload out 0 1k
.hb tones=1.3k 1k nharms=2 2 intmodmax=2 subharms=2
.end
