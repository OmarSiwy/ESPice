test circuit #1 for pz analysis:high pass filter
* KNOWN GAP: explicit PZ ports and transfer zeros are not yet exposed by the dispatcher.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: bench_pz_simplepz.expected.json
* Origin: benchmark/fixtures/pz/simplepz/circuit.sp
r1 1 0 1k
r2 2 0 1k
c1 1 2 1.0e-12
.options noacct
.pz 1 0 2 0 cur pz
.print pz all
.end
