* HSPICE-style engineering suffixes (meg, k, u, n, p) and inline params.
.param rval=2k cval=10n
V1 in 0 DC 5
R1 in out 'rval'
C1 out 0 cval
Rg out 0 1meg
.tran 1u 100u
.end
