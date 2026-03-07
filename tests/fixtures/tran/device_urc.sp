* URC (Uniform distributed RC line) transient response.
* KNOWN GAP: nonzero transient output-start time is rejected by the dispatcher.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: device_urc.expected.json
* Origin: benchmark/fixtures/devices/urc/circuit.sp
* ngspice: U device with URC model.
V1 in 0 DC 0 PULSE(0 1 1n 1n 1n 50n 100n)
U1 in out 0 umod L=100u N=10
RL out 0 10k
.model umod URC(K=1.5 FMAX=1G RPERL=1000 CPERL=1p ISPERL=0 RSPERL=0)
.tran 0.5n 200n
.end
