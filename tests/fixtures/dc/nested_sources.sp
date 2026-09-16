* Nested DC sweep ordering and superposition
* Expected results: nested_sources.expected.json
V1 a 0 0
V2 b 0 0
R1 a out 1k
R2 b out 1k
R3 out 0 1k
.dc V1 -1 1 1 V2 0 4 2
.end
