* HSPICE-style engineering suffixes (meg, k, u, n, p) and inline params.
* KNOWN GAP: nonzero transient output-start time is rejected by the dispatcher.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: hspice_suffix.expected.json
* Origin: benchmark/fixtures/parser/hspice_suffix/circuit.sp
.param rval=2k cval=10n
V1 in 0 DC 5
R1 in out 'rval'
C1 out 0 cval
Rg out 0 1meg
.tran 1u 100u
.end
