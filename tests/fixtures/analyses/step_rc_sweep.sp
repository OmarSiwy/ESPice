* Parametric Step Sweep — RC Low-pass Filter
*
* ngspice equivalent of .step param Rval LIST 1k 5k 10k
* Uses .control loop to repeat AC analysis for three R values.
*
Vin in 0 AC 1
R1 in out 1k
C1 out 0 10n
*
.options noacct
.ac DEC 20 100 10MEG
.print AC V(out)
*
.control
* Run with Rval = 1k (already set in netlist)
run
* Alter R1 to 5k and re-run
alter R1 resistance=5k
ac dec 20 100 10MEG
print ac V(out)
* Alter R1 to 10k and re-run
alter R1 resistance=10k
ac dec 20 100 10MEG
print ac V(out)
.endc
.END
