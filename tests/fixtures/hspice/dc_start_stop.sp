* HSPICE .dc var START= STOP= STEP= [CR .DC]. Oracle: analytic divider,
* v(out) = v(in)/4 at 0, 0.25, ..., 1 V.
* Expected results: dc_start_stop.expected.json
v1 in 0 1
r1 in out 3k
r2 out 0 1k
.dc v1 start=0 stop=1 step=0.25
.end
