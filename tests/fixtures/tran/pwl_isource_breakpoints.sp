* PWL current source corners land on ngspice's accepted grid
* Expected results: pwl_isource_breakpoints.expected.json
* ngspice's ISRCaccept sets each PWL corner at its exact table time, with
* none of VSRCaccept's rounding from the accepted time, so the I source keeps
* its timer breakpoints; the row-for-row time axis pins that.
I1 0 a PWL(0 0 0.33u 1m 0.71u -1m 1.3u 0.5m)
R1 a 0 1k
C1 a 0 1n
.tran 0.1u 2u
.end
