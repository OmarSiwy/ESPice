* C and L instance ic= without uic is ignored (#145)
* Expected results: device_ic_no_uic.expected.json
* ngspice manual 3.3.1: the initial conditions apply only with uic on .tran.
R1 out 0 1k
C1 out 0 1n ic=0.5
L1 n 0 1m ic=1m
R2 n 0 1k
.tran 10n 5u
.end
