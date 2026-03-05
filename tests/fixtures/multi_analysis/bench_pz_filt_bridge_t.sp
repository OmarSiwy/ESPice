BRIDGE-T FILTER
* KNOWN GAP: explicit PZ ports and transfer zeros are not yet exposed by the dispatcher.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: bench_pz_filt_bridge_t.expected.json
* Origin: benchmark/fixtures/pz/filt_bridge_t/circuit.sp
V1 1 0 12 AC 1
C1 1 2 1U
C2 2 3 1U
R3 2 0 1K
R4 1 3 1K
*
.options noacct
.OP
.PZ 1 0 3 0 VOL PZ
.PRINT PZ ALL
*
.END
