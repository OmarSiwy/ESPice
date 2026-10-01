* HSPICE MONTE=list(...) [CR .DC]: run exactly the listed trials, a range
* a:b expanded, parentheses optional. Each trial draws as it would in a
* MONTE=5 run (counter-based draws), so the plots are trials 2, 4, 5 and 3.
* Oracle: analytic, v(a) = 1 V whatever rv draws; only the trial set and
* the nominal run are checked.
* Expected results: monte_list.expected.json
.param rv=agauss(1k, 100, 1)
v1 a 0 1
r1 a 0 rv
.op sweep monte=list(2 4:5)
.op sweep monte=list 3
.end
