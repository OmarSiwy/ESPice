* Unit fixture: independent voltage source — PULSE waveform into a load.
* KNOWN GAP: nonzero transient output-start time is rejected by the dispatcher.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: device_vsource.expected.json
* Origin: benchmark/fixtures/devices/vsource/circuit.sp
V1 in 0 DC 0 PULSE(0 5 1u 1u 1u 5u 12u)
R1 in 0 1k
.tran 0.1u 30u
.end
