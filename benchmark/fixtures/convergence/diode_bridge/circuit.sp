* Full-wave diode bridge feeding a resistive load: four-junction convergence.
Vac ap an DC 5
D1 ap p DMOD
D2 n ap DMOD
D3 an p DMOD
D4 n an DMOD
RL p n 1k
.model DMOD D(IS=1e-14 N=1.2)
.op
.end
