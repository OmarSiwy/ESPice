* HSPICE inequality goals (`GOAL < v`, `GOAL > v`): a card adds no error
* while its result stays on the asked side. Three cards read the same
* v(out): vout wants 2 V, va wants below 3 V (holds near 2 V, no error),
* vb wants above 3 V (violated, so it pulls like an equality).
* Oracle: analytic. Minimize ((v-2)/2)^2 + ((v-3)/3)^2: v = 30/13 V, and
* 5 rx / (1k + rx) = v gives rx = 1000 v / (5 - v) = 6000/7 = 857.14 ohm.
* Read as equalities, va would move v; ignored, vb would leave v = 2.
* Expected results: inequality_goals.expected.json
.param rx=opt1(1k, 100, 10k)
v1 in 0 5
r1 in out 1k
r2 out 0 rx
.model optmod opt itropt=50 relin=1e-9 relout=1e-12
.dc v1 0 5 1 sweep optimize=opt1 results=vout,va,vb model=optmod
.meas dc vout find v(out) at=5 goal=2
.meas dc va find v(out) at=5 goal < 3
.meas dc vb find v(out) at=5 goal > 3
.end
