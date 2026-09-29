* .ic without UIC holds its node through the transient operating point only
* Expected results: ic_no_uic_op.expected.json
* ngspice cktload.c: MODETRANOP without MODEUIC holds every .ic node, and the
* transient starts from that point; the standalone .op ignores .ic. The .ic
* value beats the .nodeset guess on the same node.
V1 in 0 DC 1
R1 in out 1k
C1 out 0 1u
R2 out mid 1k
C2 mid 0 1u
.nodeset v(mid)=0.7 v(out)=0.9
.ic v(out)=0.2
.op
.tran 10u 3m 0 10u
.end
