* HSPICE optimization over a transient: fit R so an RC step response
* reaches 0.5 V at a measured 1 us. OPTRANGE form of the parameter.
* Oracle: analytic, R C ln 2 = 1 us with C = 1 nF gives
* R = 1e-6 / (1e-9 ln 2) = 1442.695 ohm.
* Expected results: rc_delay_fit.expected.json
.param rv=optrange(1k, 100, 10k)
v1 in 0 pwl(0 0 1p 1)
r1 in out rv
c1 out 0 1n
.model optmod opt itropt=40 relin=1e-5 relout=1e-8
.tran 5n 5u sweep optimize=optrc results=tdel model=optmod
.meas tran tdel when v(out)=0.5 rise=1 goal=1u
.end
