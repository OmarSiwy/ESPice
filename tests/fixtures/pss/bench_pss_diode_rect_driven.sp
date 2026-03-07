* PSS fixture: half-wave rectifier under sine drive, nonlinear PSS.
* Expected results: bench_pss_diode_rect_driven.expected.json
* Origin: benchmark/fixtures/pss/diode_rect_driven/circuit.sp
Vin in 0 DC 0 SIN(0 5 1k)
D1 in out dm
.model dm D(is=1e-14)
R1 out 0 10k
C1 out 0 1u
* Card is ESPice's documented form (freq samples), not ngspice's
* gfreq/tstab/oscnob/harms card: tstab and oscnob have no Options equivalent.
.pss 1k 256
.end
