* Bypass fixture: small driven RC core + 20-diode quiescent bias string;
* KNOWN GAP: nonzero transient output-start time is rejected by the dispatcher.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: bench_bypass_gated_branch.expected.json
* Origin: benchmark/fixtures/bypass/gated_branch/circuit.sp
* the string settles at t~0 and stays latent for the whole run.
Vdd vdd 0 DC 5
Vin in 0 DC 0 SIN(0 1 100k)
R1 in a 1k
C1 a 0 1n
Da a 0 dm
Rb vdd b1 10k
Db1 b1 b2 dm
Db2 b2 b3 dm
Db3 b3 b4 dm
Db4 b4 b5 dm
Db5 b5 b6 dm
Db6 b6 b7 dm
Db7 b7 b8 dm
Db8 b8 b9 dm
Db9 b9 b10 dm
Db10 b10 b11 dm
Db11 b11 b12 dm
Db12 b12 b13 dm
Db13 b13 b14 dm
Db14 b14 b15 dm
Db15 b15 b16 dm
Db16 b16 b17 dm
Db17 b17 b18 dm
Db18 b18 b19 dm
Db19 b19 b20 dm
Db20 b20 0 dm
.model dm D(is=1e-14)
.tran 0.1u 100u
.end
