* HB small-signal analyses linearize about one tone; a multi-tone .hb card cannot feed them.
* Expected results: hbac_multitone_hb.expected.json
Vin in 0 AC 1 SIN(0 1 1k)
V2 b in SIN(0 1 1.3k)
R1 b out 1k
C1 out 0 1u
.hb tones=1k 1.3k nharms=2 2
.hbac dec 2 10 1k
.end
