* Diode forward I-V at multiple temperatures.
* Tests temperature coefficients (XTI, EG, TCV).
V1 anode 0 DC 0
D1 anode 0 DMOD
.model DMOD D(IS=1e-14 N=1.05 RS=5 XTI=3 EG=1.11)
.dc V1 0 0.9 0.005 TEMP -40 125 55
.end
