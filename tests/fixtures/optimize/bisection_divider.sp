* HSPICE bisection (METHOD=BISECTION): find the bottom resistor of a
* divider where v(out) at v1 = 5 V first exceeds its GOAL. The initial
* value is ignored; the limits bracket the goal (100 fails, 10k passes).
* Oracle: analytic, 5 rx / (1k + rx) = 2 V at rx = 2k/3 = 666.67 ohm; the
* result is the last passing value, within RELIN * 9900 ohm above it.
* Expected results: bisection_divider.expected.json
.param rx=opt1(5k, 100, 10k)
v1 in 0 5
r1 in out 1k
r2 out 0 rx
.model optmod opt method=bisection relin=1e-8 relout=1e-6 itropt=60
.dc v1 0 5 1 sweep optimize=opt1 result=vout model=optmod
.meas dc vout find v(out) at=5 goal=2
.end
