* Diode forward bias DC operating point (Shockley equation).
V1 a 0 DC 0.7
R1 a b 100
D1 b 0 DMOD
.model DMOD D(IS=1e-14 N=1)
.op
.end
