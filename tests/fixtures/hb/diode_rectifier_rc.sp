* Nonlinear HB spectrum from an independent settled time-domain solution
* KNOWN GAP: HB does not yet drive the solve from the physical source waveforms and amplitudes.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: diode_rectifier_rc.expected.json
Vin in 0 SIN(0 2 1k)
Rsrc in a 100
D1 a out dm
Rload out 0 1k
C1 out 0 100n
.model dm D(is=1e-14 rs=1)
.hb 1k 32
.end
