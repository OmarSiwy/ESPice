* PZ fixture: two cascaded RC sections, two real poles.
* KNOWN GAP: explicit PZ ports and transfer zeros are not yet exposed by the dispatcher.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: bench_pz_two_pole.expected.json
* Origin: benchmark/fixtures/pz/two_pole/circuit.sp
Vin in 0 DC 0 AC 1
R1 in n1 1k
C1 n1 0 100n
R2 n1 out 10k
C2 out 0 10n
.pz in 0 out 0 vol pz
.end
