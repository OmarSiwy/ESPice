* .options maxord=1 under the default trap method is backward Euler, as in
* ngspice (dctran.c:900 never raises the order past maxord) (#56).
* Oracle: ngspice 45 measures vmax = 7.584708e-02 on this LC tank: BE
* damps it from 1 V, where the trapezoid would keep it near 1 V.
* Expected results: trap_maxord1_ngspice.expected.json
L1 n 0 1u
C1 n 0 1n
.ic v(n)=1
.tran 10n 2u 0 50n uic
.options method=trap maxord=1
.meas tran vmax max v(n) from=1.5u to=2u
.end
