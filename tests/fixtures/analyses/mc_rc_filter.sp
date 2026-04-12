* Monte Carlo Analysis — RC Low-pass Filter Corner Frequency
*
* Varies R and C by ±10% using ngspice agauss() in .control loop.
* agauss(mean, sigma, sigma_multiples) returns a Gaussian random value.
* Each run re-evaluates the params, giving a Monte Carlo distribution.
*
* Nominal single-run netlist (params evaluated once per run):
.param Rnom=10k Cnom=10n
.param Rval=agauss(10k,1k,3)
.param Cval=agauss(10n,1n,3)
*
Vin in 0 AC 1
R1 in out {Rval}
C1 out 0 {Cval}
Rload out 0 1MEG
*
.options noacct
.ac DEC 20 10 1MEG
.measure AC f3db WHEN VDB(out)=-3
.print AC V(out)
.END
