* HSPICE .sn TRES= PERIOD= [CR .SN] runs as .pss, PERIOD/TRES steps a
* period. Oracle: pss/rc_default's, the analytic periodic RC orbit
* offset + Im[A*H(jw)*exp(jwt)], H = 1/(1 + jwRC).
* Expected results: sn_rc.expected.json
Vin in 0 SIN(0 1 1k)
R1 in out 1000
C1 out 0 1e-06
.sn tres=3.90625u period=1m
.end
