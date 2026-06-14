* HSPICE bisection optimization (METHOD=BISECTION) is not implemented:
* the deck must be refused, not run as Levenberg-Marquardt.
* Expected results: optimize_bisection.expected.json
.param rx=opt1(1k, 100, 10k)
v1 in 0 5
r1 in out 1k
r2 out 0 rx
.model optmod opt method=bisection
.dc v1 0 5 1 sweep optimize=opt1 results=vout model=optmod
.meas dc vout find v(out) at=5 goal=2
.end
