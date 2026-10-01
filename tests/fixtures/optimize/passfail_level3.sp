* HSPICE pass/fail bisection through LEVEL=3: the WHEN measure has a value
* only while the divider output reaches 2 V somewhere in the sweep, so the
* search finds the smallest rx that still passes.
* Oracle: analytic, max v(out) = 5 rx / (1k + rx) >= 2 V for
* rx >= 2k/3 = 666.67 ohm; the last passing value is within RELIN * 9900
* ohm above it.
* Expected results: passfail_level3.expected.json
.param rx=opt1(5k, 100, 10k)
v1 in 0 5
r1 in out 1k
r2 out 0 rx
.model optmod opt level=3 relin=1e-8 itropt=60
.dc v1 0 5 0.1 sweep optimize=opt1 results=vcross model=optmod
.meas dc vcross when v(out)=2 goal=5
.end
