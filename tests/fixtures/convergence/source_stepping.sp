* Convergence Aid — Source Stepping
*
* Source stepping gradually ramps all independent sources from 0
* to their final values to help DC convergence in nonlinear circuits
* ngspice: .options srcsteps=1  (or ITL6 for source stepping iterations)
* xyce:    .options DCSTEP=1
*
* Hard-to-converge diode rectifier bridge
VIN in 0 DC 10
D1 in a DMOD
D2 a b DMOD
D3 b 0 DMOD
D4 in c DMOD
D5 c b DMOD
Rload b 0 1k
Cload b 0 100u
*
.model DMOD D (IS=1E-14 N=1.0 RS=0.5 CJO=2P BV=100)
*
* Enable source stepping for DC convergence
.options noacct srcsteps=1 ITL1=200 ITL2=50
.op
.print OP V(a) V(b) V(c) V(in)
.END
