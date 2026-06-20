* Box truncation over incommensurate tones: a square law needs no period
* Expected results: two_tone_box_square.expected.json
V1 a 0 SIN(0 1 1000)
V2 b 0 SIN(0 .5 1414.213562373095)
Bout out 0 V=(V(a)+V(b))^2
Rload out 0 1k
.hb tones=1000 1414.213562373095 nharms=2 2 intmodmax=4
.end
