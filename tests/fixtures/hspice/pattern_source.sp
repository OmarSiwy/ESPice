* HSPICE pattern sources [SA Ch.9 "Pattern Source"; CR .PAT]. Oracle:
* analytic. v1: vhi 1, vlo 0, td 1n, tr 0.2n, tf 0.4n, 2 ns bits;
* b1011 r=1 rb=2 then b0m1 expand to 1011 011 0m1, so the bit centres
* 2n, 4n, ... 20n read 1 0 1 1 0 1 1 0 0.5 1, and the delay holds the
* first bit (1 at 0.5n). Edges ramp across the bit boundaries (the fall
* at 3n runs 2.8n to 3.2n: 0.5 at 3n). v2: .pat a2=[b10 b01] r=1 is
* 1001 1001 at 1 ns bits from 0: 2, 0, 0, 2, 2, 0, 0, 2 at the centres.
* Expected results: pattern_source.expected.json
.pat a2=[b10 b01] r=1
v1 a 0 pat (1 0 1n 0.2n 0.4n 2n b1011 r=1 rb=2 b0m1)
r1 a 0 1k
v2 b 0 pat 2 0 0 0.1n 0.1n 1n a2
r2 b 0 1k
.tran 0.1n 22n
.end
