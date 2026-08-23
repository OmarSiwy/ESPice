* C and L instance ic= seed a uic transient (#145)
* Expected results: device_ic_uic.expected.json
* ngspice CAPload/INDload under MODEUIC start from CAPinitCond/INDinitCond.
R1 out 0 1k
C1 out 0 1n ic=0.5
L1 n 0 1m ic=1m
R2 n 0 1k
.tran 10n 5u uic
.end
