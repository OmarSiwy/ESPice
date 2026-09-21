* Two capacitive dividers whose island sits behind a series short (#90): a
* 0 V ammeter (i1) and a 1 mOhm resistor (i2). Neither gives the island a
* DC path, so the transient operating point settles it by charge division,
* as for a plain divider: v = 1 V * C1/(C1 + C2) = 0.5 V from t = 0.
* Oracle: analytic; ngspice 45 gives 0.5 and 0.4999959 at t = 0.
* Expected results: island_series_short.expected.json
V1 in 0 1
C1 in m1 1n
Vam m1 i1 0
C2 i1 0 1n
C3 in m2 1n
Rs m2 i2 1m
C4 i2 0 1n
.tran 1n 10n
.end
