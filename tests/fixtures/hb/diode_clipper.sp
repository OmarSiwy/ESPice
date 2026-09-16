* Nonlinear HB spectrum from an independent settled time-domain solution
* KNOWN GAP: HB does not yet drive the solve from the physical source waveforms and amplitudes.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: diode_clipper.expected.json
Vin in 0 SIN(0 1 1k)
R1 in out 1k
D1 out 0 dm
.model dm D(is=1e-14)
C1 out 0 10n
.hb 1k 32
.end
