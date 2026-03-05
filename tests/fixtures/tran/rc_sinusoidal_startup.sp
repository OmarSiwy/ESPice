* Sinusoidal forced response plus initial-condition transient
* Expected results: rc_sinusoidal_startup.expected.json
Vin in 0 SIN(0 1 1k)
R1 in out 1k
C1 out 0 1u
.tran .2u 4m 0 .2u
.options reltol=1e-6
.end
