* HSPICE .dc var DEC np start stop [CR .DC]: np points per decade.
* Oracle: analytic divider, v(out) = v(in)/4 at 1, 3.162, 10, 31.62, 100 V.
* Expected results: dc_dec_grid.expected.json
v1 in 0 1
r1 in out 3k
r2 out 0 1k
.dc v1 dec 2 1 100
.end
