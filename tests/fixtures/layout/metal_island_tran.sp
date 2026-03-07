Synthetic reduction of grounded floating-metal capacitance from StrongARM PEX
* KNOWN GAP: nonzero transient output-start time is rejected by the dispatcher.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: metal_island_tran.expected.json
* Origin: benchmark/fixtures/layout/metal_island_tran/circuit.sp
* Extracted metal connected only to ground capacitance must remain at zero.
V1 in 0 DC 1 PULSE(1 2 1n 10p 10p 2n 4n)
R1 in 0 1k
Cmetal metal 0 1p
.tran 1p 2n
.end
