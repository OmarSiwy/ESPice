* .connect b c makes b and c one net [CR .CONNECT]. Oracle: analytic,
* 1 V across 1k through the joined net.
* Expected results: connect.expected.json
v1 b 0 1
.connect b c
r1 c 0 1k
.op
.end
