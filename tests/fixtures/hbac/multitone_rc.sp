* HB AC on a linear RC under two large tones is plain AC on sideband 0
* Expected results: multitone_rc.expected.json
V1 a 0 SIN(0 1 1k) AC 1
V2 b 0 SIN(0 1 1.3k)
R1 a out 1k
R2 b out 1k
C1 out 0 1u
.hb tones=1k 1.3k nharms=2 2
.hbac lin 3 100 300
.end
