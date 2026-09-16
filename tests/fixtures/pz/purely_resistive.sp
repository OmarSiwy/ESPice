* No dynamic states means no finite poles
* KNOWN GAP: explicit PZ ports and transfer zeros are not yet exposed by the dispatcher.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: purely_resistive.expected.json
Vin in 0 10
R1 in out 1000
R2 out 0 3000
.pz
.end
