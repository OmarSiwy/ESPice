* HSPICE Monte Carlo: `.dc MONTE=` draws agauss per trial at a fixed seed,
* one global site (both resistors read rv, so they move together) and one
* per-element site.
* Oracle: analytic. v(b) = (rv + d)/(2k + d) with rv ~ N(1k, 50) shared
* and d ~ N(0, 50) local: to first order the mean is 0.5 and sigma =
* sqrt((50/2k)^2 + (50/4k)^2) = 27.95 mV (21.7 mV were rv drawn per use).
* Repeat runs are bit-identical.
* Expected results: monte_divider.expected.json
.param rv=agauss(1k, 150, 3)
v1 a 0 1
r1 a b '2k - rv'
r2 b 0 '(rv + agauss(0, 50, 1))'
.option seed=7
.dc monte=2000
.end
