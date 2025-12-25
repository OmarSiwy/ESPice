* Unit fixture: N-MESFET bias point.
Vdd vdd 0 DC 5
Vg g 0 DC -0.5
Rd vdd d 1k
Z1 d g 0 nmf
.model nmf NMF(vto=-1.5 beta=2m alpha=2 lambda=5m)
.op
.end
