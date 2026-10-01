* HSPICE .NET (obsolete .LIN predecessor) on a resistive T network, both
* ports open (.NET V(c) Iin, the Z form): R1 = 10, R2 = 100 to ground,
* R3 = 20, so Z = [[110, 100], [100, 120]]; S against RIN = 50 and
* ROUT = 75. Same network and answer as net_tpad_y.
* Oracle: analytic (see the expected.json derivation).
* Expected results: net_tpad_z.expected.json
IIN 0 a ac 1
R1 a b 10
R2 b 0 100
R3 b c 20
.ac lin 1 1k 1k
.net v(c) iin rout=75 rin=50
.end
