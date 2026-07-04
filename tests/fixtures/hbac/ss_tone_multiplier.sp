* SS_TONE takes the RF tone out of the large-signal spectrum; .hbac drives it
* Expected results: ss_tone_multiplier.expected.json
Vrf rf 0 DC 0 AC 1
Vlo lo 0 SIN(0 1 1k 0 0 90)
Bout out 0 V=V(rf)*V(lo)
Rload out 0 1k
.hb tones=1k 1.1k nharms=3 3 ss_tone=2
.hbac lin 2 1.1k 1.2k
.end
