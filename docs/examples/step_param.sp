RC corner against R, with .step
.param rval=1k
V1 in 0 DC 0 AC 1
R1 in out {rval}
C1 out 0 100n
.ac dec 5 10 100k
.step param rval list 1k 2k 4k
.meas ac f3db WHEN vdb(out)=-3
.end
