* A POLE card lists both roots of a complex pair (the manual's Chebyshev
* example writes 0.5,0.1379 and 0.5,-0.1379). A complex root without its
* conjugate is refused, not run as NaN.
* Expected results: pole_unpaired_root.expected.json
v1 a 0 dc 1 ac 1
e1 b 0 pole a 0 1 / 1 1e3,1e3
r1 b 0 1k
.op
.end
