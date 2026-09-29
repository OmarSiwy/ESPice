* HSPICE .lin on the matched 6.02 dB pi pad between P-element ports: S, Y, Z, H and the two-port noise parameters (a matched pad at 290 K has NF = NFMIN = 4).
* Oracle: analytic (see the expected.json derivation).
* Expected results: lin_pad.expected.json
P1 a 0 port=1 z0=50
P2 b 0 port=2 z0=50
R1 a 0 150
R2 a b 37.5
R3 b 0 150
.temp 16.85
.option tnom=16.85
.ac dec 1 1000 100000
.lin noisecalc=1
.end