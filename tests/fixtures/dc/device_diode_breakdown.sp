* Diode reverse breakdown region.
* Expected results: device_diode_breakdown.expected.json
* Origin: benchmark/fixtures/devices/diode_breakdown/circuit.sp
* Tests avalanche breakdown (BV, IBV parameters).
V1 anode 0 DC 0
R1 anode cathode 100
D1 cathode 0 DMOD
.model DMOD D(IS=1e-14 N=1 BV=15 IBV=1e-3 RS=1)
.dc V1 -20 0 0.05
.end
