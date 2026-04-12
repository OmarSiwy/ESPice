* Convergence Aid — Pseudo-transient (PTran)
*
* Pseudo-transient runs a short transient simulation to find a DC OP
* when standard Newton-Raphson DC iteration fails to converge.
* ngspice: .options ptranmax=<time>  enables pseudo-transient fallback
* xyce:    .options PSEUDOTRANSIENT=1
*
* Difficult circuit: CMOS bistable latch (two stable DC solutions)
VDD vdd 0 DC 1.8
*
* Cross-coupled CMOS inverter pair (SR latch core)
MN1 q  qb  0   0   NMOD W=1u L=180n
MP1 q  qb  vdd vdd PMOD W=2u L=180n
MN2 qb q   0   0   NMOD W=1u L=180n
MP2 qb q   vdd vdd PMOD W=2u L=180n
*
* Weak set bias to push toward Q=1 state
Rset vdd q 1MEG
*
.model NMOD NMOS LEVEL=1 VTO=0.42 KP=270u LAMBDA=0.01
.model PMOD PMOS LEVEL=1 VTO=-0.42 KP=90u LAMBDA=0.01
*
* Enable pseudo-transient fallback for DC convergence
.options noacct ptranmax=1u ITL1=200 ITL2=50
.op
.print OP V(q) V(qb)
.END
