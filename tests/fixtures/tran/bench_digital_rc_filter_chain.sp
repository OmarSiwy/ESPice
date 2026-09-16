* Clocked RC chain emulating a digital buffer delay line (transient edges).
* KNOWN GAP: nonzero transient output-start time is rejected by the dispatcher.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: bench_digital_rc_filter_chain.expected.json
* Origin: benchmark/fixtures/digital/rc_filter_chain/circuit.sp
Vclk clk 0 DC 0 PULSE(0 5 0 1n 1n 50n 100n)
R1 clk n1 1k
C1 n1 0 10p
R2 n1 n2 1k
C2 n2 0 10p
R3 n2 out 1k
C3 out 0 10p
.tran 1n 400n
.end
