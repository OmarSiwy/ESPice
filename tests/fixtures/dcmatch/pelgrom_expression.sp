* .variation sigma as an expression over each device's W and L (#100):
* Pelgrom scaling, sigma(vto) = A_VT/sqrt(W*L) with A_VT = 5 mV*um, read
* per device. W and L are the device's own values in meters.
* Oracle: analytic. Each diode-connected level-1 nmos carries a fixed 10 uA,
* so v(g) = vto + sqrt(2*I*L/(kp*W)) and dv(g)/dvto = 1. Per device:
* m1 (1u x 1u) sigma 5 mV, m2 (4u x 1u) sigma 2.5 mV; v(a,b) has
* total_3sigma = 3*sqrt(5^2 + 2.5^2) mV = 16.77051 mV.
* Expected results: pelgrom_expression.expected.json
.param avt=5m
.model nch nmos level=1 vto=0.5 kp=100u
i1 0 a 10u
i2 0 b 10u
m1 a a 0 0 nch w=1u l=1u
m2 b b 0 0 nch w=4u l=1u
.variation
.local_variation
nmos nch vto='avt*1u/sqrt(w*l)'
.end_local_variation
.end_variation
.dcmatch v(a,b)
.end
