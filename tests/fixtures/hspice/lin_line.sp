* HSPICE .lin through a matched lossless line (T element, z0 = 50, td = 1 ns):
* S21 = e^(-j w td) and a group delay of exactly td, taken by .lin gdcalc=1
* from a central difference across the line's frequency-dependent stamp.
* Oracle: analytic (see the expected.json derivation).
* Expected results: lin_line.expected.json
P1 a 0 port=1 z0=50
T1 a 0 b 0 z0=50 td=1n
P2 b 0 port=2 z0=50
.ac lin 3 100meg 300meg
.lin gdcalc=1
.end
