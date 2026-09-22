* Capacitor AC impedance: verifies 1/(jwC) frequency response.
* Expected results: device_capacitor_ac.expected.json
* Origin: benchmark/fixtures/devices/capacitor_ac/circuit.sp
V1 in 0 DC 0 AC 1
R1 in mid 1k
C1 mid 0 10n
.ac dec 20 1 1G
.end
