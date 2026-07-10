* HSPICE .power [CR .POWER]: AVG, RMS, MAX and MIN of a signal as
* power<N>_avg, _rms, _max and _min. A bare voltage source name reads the
* power it absorbs, v(n+,n-) * i(source). Oracle: analytic. v1 drives
* sin(2 pi 1MHz t) into 1k, so it absorbs -sin^2 / 1k: over one period
* avg -0.5 mW, rms sqrt(3/8) mW, max 0, min -1 mW. v2 holds 2 V across
* 1k + 1k: -2 mW throughout. i(v1) over the period: avg 0, max 1 mA.
* Expected results: power.expected.json
.option delmax=1n
v1 a 0 sin(0 1 1meg)
r1 a 0 1k
v2 b c 2
r2 b 0 1k
r3 c 0 1k
.power v1 ref=top from=0 to=1u
.power v2 from=0.5u to=1.5u
.power i(v1) from=0 to=1u
.tran 1n 2u
.end
