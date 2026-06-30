* HSPICE optimization under .step: one fit per step point, each from the
* step point's values. The top resistor rt steps over 1k and 2k; each fit
* puts v(out) at 2 V with v1 = 5 V. The .op after the optimizing card runs
* at each point's optimum.
* Oracle: analytic, 5 rx / (rt + rx) = 2 at rx = 2 rt / 3: 666.67 and
* 1333.33 ohm, so i(v1) = -5 / (rt + rx) = -3 mA and -1.5 mA at the .op.
* Expected results: step_optimize.expected.json
.param rx=opt1(1k, 100, 10k)
.param rt=1k
v1 in 0 5
r1 in out rt
r2 out 0 rx
.model optmod opt itropt=50 relin=1e-9 relout=1e-12
.step param rt list 1k 2k
.dc v1 0 5 1 sweep optimize=opt1 results=vout model=optmod
.op
.meas dc vout find v(out) at=5 goal=2
.end
