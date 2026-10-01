* HSPICE .NET (obsolete .LIN predecessor) on a resistive T network, both
* ports voltage sources (.NET I(Vout) Vin, the Y form): R1 = 10, R2 = 100
* to ground, R3 = 20, so Z = [[110, 100], [100, 120]]; S against RIN = 50
* and ROUT = 75. net_tpad_z drives the same network with currents.
* Oracle: analytic (see the expected.json derivation).
* Expected results: net_tpad_y.expected.json
VIN a 0 ac 1
R1 a b 10
R2 b 0 100
R3 b c 20
VOUT c 0 0
.ac lin 1 1k 1k
.net i(vout) vin rout=75 rin=50
.end
