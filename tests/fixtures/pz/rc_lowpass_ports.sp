* Transfer poles and zeros with explicit input and output ports
* KNOWN GAP: explicit PZ ports and transfer zeros are not yet exposed by the dispatcher.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: rc_lowpass_ports.expected.json
Vin in 0 0
R1 in out 1k
C1 out 0 1u
.pz in 0 out 0 vol pz
.end
