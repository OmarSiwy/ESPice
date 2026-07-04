* HB XF on a linear RC under two large tones is the plain impedance on sideband 0
* Expected results: multitone_rc.expected.json
V1 a 0 SIN(0 1 1k)
V2 b 0 SIN(0 1 1.3k)
R1 a out 1k
R2 b out 1k
C1 out 0 1u
.hb tones=1k 1.3k nharms=2 2
.hbxf v(out) lin 3 100 300
.end
