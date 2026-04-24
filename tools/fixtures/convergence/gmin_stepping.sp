* Convergence Aid — Gmin Stepping
*
* Gmin stepping adds a small conductance to every PN junction,
* then gradually reduces it to zero, guiding the solver to the solution.
* ngspice: .options gmin=1e-12  (default); gmindc controls stepping
* The solver tries GMIN stepping automatically on DC convergence failure.
*
* Hard-to-converge circuit: back-to-back diodes with low leakage
VDD vdd 0 DC 5
R1 vdd n1 100
D1 n1 n2 DLOW
D2 n2 0 DLOW
*
* Second branch: Zener clamp
R2 vdd n3 220
Dz n3 0 DZEN
*
* Ultra-low-leakage diode model (hard to converge without Gmin)
.model DLOW D (IS=1E-17 N=1.0 RS=10 CJO=0.1P BV=60 IBV=1n)
.model DZEN D (IS=1E-14 N=1.0 RS=1 BV=5.1 IBV=5m)
*
.options noacct gmin=1e-12 ITL1=150 ITL2=50
.op
.print OP V(n1) V(n2) V(n3)
.END
