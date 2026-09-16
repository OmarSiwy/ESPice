* Harmonic balance with physical voltage drive
* KNOWN GAP: HB does not yet drive the solve from the physical source waveforms and amplitudes.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: dc_offset.expected.json
Vin in 0 SIN(3 2 1k)
R1 in out 1000
C1 out 0 1e-06
.hb 1k 8
.end
