* HSPICE .temp t1 t2 t3 runs every analysis at each temperature [CR .TEMP];
* the ngspice reading was one sweep point at -55 degC. TNOM is HSPICE's
* 25 degC. Oracle: ngspice 45 at each temperature with tnom=25.
* Expected results: temp_list.expected.json
i1 0 a 1m
d1 a 0 dmod
.model dmod d is=1e-14 n=1.2 rs=5 eg=1.11 xti=3
.temp -55 25 125
.op
.end
