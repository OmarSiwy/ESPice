* Parser Test — .DATA block parametric sweep (hspice)
*
* .data defines a named table of parameter values
* .step data <name> steps through each row
*
.param Rval=1k Cval=10n
*
Vin in 0 AC 1
R1 in out {Rval}
C1 out 0 {Cval}
*
* Data block: each row is one (Rval, Cval) combination
.data rcvals
+ Rval    Cval
+ 1k      10n
+ 5k      2n
+ 10k     1n
.enddata
*
.options noacct
.ac DEC 20 100 100MEG
.print AC V(out)
*
* Step through the data block
.step data rcvals
.END
