* Unit fixture: voltage-controlled switch with hysteresis, ramp control.
* KNOWN GAP: nonzero transient output-start time is rejected by the dispatcher.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: device_switch.expected.json
* Origin: benchmark/fixtures/devices/switch/circuit.sp
Vc ctl 0 PWL(0 0 10m 5 20m 0)
Vs in 0 DC 10
S1 in out ctl 0 sw1
RL out 0 1k
.model sw1 SW(vt=2.5 vh=0.5 ron=1 roff=1meg)
.tran 0.1m 20m
.end
