* Diode full I-V characteristic: forward + reverse sweep.
* Expected results: device_diode_iv_sweep.expected.json
* Origin: benchmark/fixtures/devices/diode_iv_sweep/circuit.sp
* Exercises Shockley equation across all regions.
V1 anode 0 DC 0
D1 anode 0 DMOD
.model DMOD D(IS=1e-14 N=1 RS=10 BV=100 IBV=1e-10)
.dc V1 -5 1 0.005
.end
