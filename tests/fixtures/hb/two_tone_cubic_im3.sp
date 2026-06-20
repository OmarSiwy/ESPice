* Two-tone intermodulation of a cubic, diamond truncation at order 3
* Expected results: two_tone_cubic_im3.expected.json
V1 a 0 SIN(0 1 1k)
V2 b 0 SIN(0 .5 1.3k)
Bout out 0 V=(V(a)+V(b))^3
Rload out 0 1k
.hb tones=1k 1.3k nharms=3 3 intmodmax=3
.end
