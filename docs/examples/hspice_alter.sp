RC step response in the HSPICE dialect
.param rval=1k cval=2p
V1 in 0 PULSE 0 1 0 10p 10p 50n 100n
R1 in out rval
C1 out 0 cval
.tran 10p 20n
.measure t50 WHEN v(out)=0.5 RISE=1
.alter
.param rval=2k
.end
