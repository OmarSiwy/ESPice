* HSPICE bisection (METHOD=BISECTION) over two parameters: the manual's
* AND over several bisected parameters is not specified, so the deck must
* be refused, not run some other way.
* Expected results: optimize_bisection.expected.json
.param rx=opt1(1k, 100, 10k)
.param ry=opt1(1k, 100, 10k)
v1 in 0 5
r1 in out ry
r2 out 0 rx
.model optmod opt method=bisection
.dc v1 0 5 1 sweep optimize=opt1 results=vout model=optmod
.meas dc vout find v(out) at=5 goal=2
.end
