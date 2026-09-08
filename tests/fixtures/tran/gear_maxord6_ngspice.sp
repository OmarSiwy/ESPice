* method=gear with maxord=6 runs Gear-2, as ngspice does: dctran.c:900
* raises the order from 1 to 2 and never further (#56).
* Oracle: ngspice 45 measures vmax = 3.406919e-01 at maxord 2, 3 and 6 alike.
* Expected results: gear_maxord6_ngspice.expected.json
L1 n 0 1u
C1 n 0 1n
.ic v(n)=1
.tran 10n 2u 0 50n uic
.options method=gear maxord=6
.meas tran vmax max v(n) from=1.5u to=2u
.end
