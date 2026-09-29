* Three tones through a cubic: products that land on one line merge
* Expected results: three_tone_cubic.expected.json
V1 a 0 SIN(0 1 1k)
V2 b a SIN(0 .5 1.3k)
V3 c b SIN(0 .25 1.7k)
Bout out 0 V=V(c)^3
Rload out 0 1k
.hb tones=1k 1.3k 1.7k nharms=3 3 3 intmodmax=3
.end
