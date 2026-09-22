* Full-wave bridge with a floating load
* Expected results: bridge_op_1.expected.json
Vin in 0 1
Rsrc in acp 10
D1 acp vp dm
D2 0 vp dm
D3 vn acp dm
D4 vn 0 dm
Rload vp vn 1k
.model dm D(is=1e-14 rs=.1)
.op
.options reltol=1e-6 abstol=1e-12 vntol=1e-8 method=gear temp=27 tnom=27
.end
