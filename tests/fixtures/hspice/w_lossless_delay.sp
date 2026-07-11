* HSPICE W element, lossless and matched: the far end is the near end delayed
* by td = l*sqrt(L0*C0) = 1 ns.
* Expected results: w_lossless_delay.expected.json
* Oracle (analytic): v(a) = v(in)/2 (the line looks like 50 ohm), and
* v(b)(t) = v(a)(t - 1 ns).
v1 in 0 pwl(0 0 1n 0 1.5n 1 4n 1 4.5n 0)
rs in a 50
w1 a 0 b 0 rlgcmodel=line n=1 l=0.1
rl b 0 50
.model line w modeltype=rlgc n=1 lo=500n co=200p
.tran 10p 7n
.end
