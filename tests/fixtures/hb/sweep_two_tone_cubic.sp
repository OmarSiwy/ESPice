* SWEEP on .hb reruns the two-tone cubic once per divider point
* Expected results: sweep_two_tone_cubic.expected.json
.param rl=1k
V1 a 0 SIN(0 1 1k)
V2 b 0 SIN(0 .5 1.3k)
Bout out 0 V=(V(a)+V(b))^3
R1 out div 1k
R2 div 0 rl
.hb tones=1k 1.3k nharms=3 3 intmodmax=3 sweep rl poi 2 1k 3k
.end
