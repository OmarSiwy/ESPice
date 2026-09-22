* TSTART suppresses output without restarting circuit history
* KNOWN GAP: nonzero transient output-start time is rejected by the dispatcher.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: output_start_time.expected.json
Vin in 0 SIN(0 1 1k)
R1 in out 1000
R2 out 0 3000
.tran 1u 3m 1m 1u
.end
