Parameters and expressions
.param f0=1k c=10n
.param r={1/(2*3.14159265*f0*c)}
V1 in 0 DC 0 AC 1
R1 in out {r}
C1 out 0 {c}
.ac dec 20 100 10k
.meas ac f3db WHEN vdb(out)=-3
.end
