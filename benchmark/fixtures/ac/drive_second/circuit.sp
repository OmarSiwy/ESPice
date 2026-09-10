* AC fixture: two V cards, AC 1 on the SECOND. The driven card is the one
* that names AC, not the one that comes first: v(a) = 0, v(b) = 1.
V1 a 0 DC 0
V2 b 0 DC 0 AC 1
R1 a 0 1k
R2 b 0 1k
.ac dec 2 1k 10k
.end
