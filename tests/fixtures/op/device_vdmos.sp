* VDMOS power MOSFET operating point.
* Expected results: device_vdmos.expected.json
* Origin: benchmark/fixtures/devices/vdmos/circuit.sp
Vdd vdd 0 DC 12
Vg g 0 DC 6
Rd vdd d 10
M1 d g 0 VMOD
.model VMOD VDMOS(VTO=3 KP=2 LAMBDA=0.02 RG=5 RD=0.1 RS=0.1 RB=0.1 CGDMAX=100p CGDMIN=10p CGS=50p A=1 IS=1e-14)
.op
.end
