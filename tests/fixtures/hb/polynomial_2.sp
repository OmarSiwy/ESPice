* Nonlinear harmonic generation without device-model ambiguity
* KNOWN GAP: HB does not yet drive the solve from the physical source waveforms and amplitudes.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: polynomial_2.expected.json
Vin in 0 SIN(0 1 1k)
Bout out 0 V=V(in)^2
Rload out 0 1k
.hb 1k 8
.end
