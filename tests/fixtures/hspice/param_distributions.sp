* Statistical functions fold to their nominal outside Monte Carlo (HSPICE
* [SA Ch.20]); Monte Carlo sampling is future work. Oracle: analytic,
* 1 V across 1k || 2k draws 1.5 mA.
* Expected results: param_distributions.expected.json
.param rv=agauss(1k,100,3) gv='limit(2k, 500)' uv=unif(1k, 0.1) av=aunif(1k, 50)
v1 a 0 1
r1 a 0 rv
r2 a 0 gv
r3 a b uv
r4 b 0 av
.op
.end
