Half-wave rectifier
* A 50 Hz, 10 V peak sine through a diode into an RC load.
V1 in 0 SIN(0 10 50)
D1 in out dmod
R1 out 0 1k
C1 out 0 100u
.model dmod D(IS=1e-14 N=1.05 RS=0.5 CJO=10p)
.tran 0.1m 60m
.meas tran vpeak MAX v(out)
.meas tran vmin MIN v(out) FROM=40m TO=60m
.end
