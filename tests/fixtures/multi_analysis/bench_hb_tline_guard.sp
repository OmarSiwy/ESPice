* Matched transmission line in harmonic balance; physical source waveform.
* KNOWN GAP: HB does not yet drive the solve from the physical source waveforms and amplitudes.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: bench_hb_tline_guard.expected.json
* Origin: benchmark/fixtures/hb/tline_guard/circuit.sp
Vin in 0 DC 0 SIN(0 1 1k)
RS in a 50
T1 a 0 b 0 Z0=50 TD=1n
RL b 0 50
.op
.hb 1k
.end
