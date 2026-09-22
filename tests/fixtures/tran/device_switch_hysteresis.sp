* Voltage-controlled switch: detailed hysteresis loop.
* KNOWN GAP: nonzero transient output-start time is rejected by the dispatcher.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: device_switch_hysteresis.expected.json
* Origin: benchmark/fixtures/devices/switch_hysteresis/circuit.sp
* Slow ramp up then down to trace full hysteresis.
Vc ctl 0 PWL(0 0 5m 5 10m 0 15m 5 20m 0)
Vs in 0 DC 10
S1 in out ctl 0 sw1
RL out 0 1k
.model sw1 SW(VT=2.5 VH=0.5 RON=1 ROFF=1meg)
.tran 0.05m 20m
.end
