* HSPICE .option gmindc is the conductance across every pn junction in DC
* [CR .OPTION GMINDC] (#78). Oracle: analytic, D1 reverse-biased at 1 V:
* i(v1) = -(Is + gmindc * 1 V) = -1.0e-3 A. ngspice has no gmindc option.
* Expected results: gmindc.expected.json
.option gmindc=1e-3 post
v1 0 a 1
d1 a 0 dmod
.model dmod d(is=1e-14)
.op
.end
