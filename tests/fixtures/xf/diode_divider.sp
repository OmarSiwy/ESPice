* All-source DC and AC transfer and DC increments of a diode divider
* Expected results: diode_divider.expected.json
.options reltol=1e-9 vntol=1e-12 abstol=1e-15
V1 1 0 dc 0.8 ac 1
R1 1 2 1k
D1 2 3 dmod
V2 3 0 dc 0
I1 0 2 dc 1e-4 ac 0.5
C1 2 0 1u
.model dmod d is=1e-12 n=2
.dcxf v(2)
.dcxf v(2) tf
.dcinc
.acxf v(2) dec 5 10 100k
.acxf v(2) dec 5 10 100k tf
.end
