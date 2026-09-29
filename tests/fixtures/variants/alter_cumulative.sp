* HSPICE .alter runs, cumulative: each block edits the deck the previous
* run left [SA Ch.4]. Run 1 swaps r2's value, run 2 swaps r1 (keeping run
* 1's r2), run 3 adds r3, a new element and so a new topology.
* Oracle: analytic dividers. Base v(b) = 1/2; alter=1: 3k/(1k+3k);
* alter=2: 3k/(2k+3k); alter=3: 750/(2k+750).
* Expected results: alter_cumulative.expected.json
v1 a 0 1
r1 a b 1k
r2 b 0 1k
.op
.alter
r2 b 0 3k
.alter
r1 a b 2k
.alter
r3 b 0 1k
.end
