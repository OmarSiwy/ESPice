* Current-controlled switch: W device with ramping control current.
* KNOWN GAP: nonzero transient output-start time is rejected by the dispatcher.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: device_cswitch.expected.json
* Origin: benchmark/fixtures/devices/cswitch/circuit.sp
Vin in 0 DC 10
Vctl ctrl 0 PWL(0 0 10m 10 20m 0)
Rctl ctrl sense 1k
Vam sense 0 DC 0
W1 in out Vam csw1
RL out 0 1k
.model csw1 CSW(IT=5m IH=1m RON=1 ROFF=1meg)
.tran 0.1m 20m
.end
