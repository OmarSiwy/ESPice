* Diode junction capacitance: AC sweep to extract Cj(V).
* Expected results: device_diode_capacitance.expected.json
* Origin: benchmark/fixtures/devices/diode_capacitance/circuit.sp
* Tests CJO, VJ, M parameters via impedance measurement.
V1 anode 0 DC -2
Vac anode mid DC 0 AC 1
D1 mid 0 DMOD
.model DMOD D(IS=1e-14 N=1 CJO=10p VJ=0.7 M=0.5)
.ac dec 10 1k 1G
.end
