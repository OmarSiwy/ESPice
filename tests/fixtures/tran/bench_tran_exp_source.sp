* EXP stimulus into an RC: no other deck in the suite used one.
* KNOWN GAP: nonzero transient output-start time is rejected by the dispatcher.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: bench_tran_exp_source.expected.json
* Origin: benchmark/fixtures/tran/exp_source/circuit.sp
* PULSE, SIN and PWL are all covered several times over; EXP and SFFM were
* the two independent-source waveforms nothing exercised at all.
* Rise starts at 1us with tau 2us, fall at 6us with tau 3us.
V1 in 0 EXP(0 5 1u 2u 6u 3u)
R1 in out 1k
C1 out 0 1n
.tran 50n 20u
.end
