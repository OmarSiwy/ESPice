* Sum/difference mixing and DC generation
* Expected results: square_mixer.expected.json
V1 a 0 SIN(0 1 1000)
V2 b 0 SIN(0 .5 1414.213562373095)
Bout out 0 V=(V(a)+V(b))^2
Rload out 0 1k
.qpss 1000 1414.213562373095 2 2
.end
