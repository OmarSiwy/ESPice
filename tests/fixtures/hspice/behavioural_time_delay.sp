* Time-dependent behavioural sources: a B source of time and an E DELAY card.
* Expected results: behavioural_time_delay.expected.json
* Oracle (analytic): v(o6) = 1e3 * time. v(a) ramps 0 -> 1 V over 0..2 ms and
* holds; E7 delays it by 1 ms, so v(o7) = 0 before 1 ms, (t - 1 ms)/2 ms up to
* 3 ms, then 1. Samples avoid the delayed corners at 1 ms and 3 ms.
va a 0 pwl(0 0 2m 1)
b6 o6 0 v=time*1e3
e7 o7 0 delay a 0 td=1m
r7 o7 0 1k
.tran 10u 4m
.end
