Diode I-V curve with a DC sweep
V1 a 0 DC 0
D1 a 0 dmod
.model dmod D(IS=1e-14 N=1)
.dc V1 0 0.8 0.01
.end
