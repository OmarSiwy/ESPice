* Current-driven HB must not require a voltage source
* KNOWN GAP: HB does not yet drive the solve from the physical source waveforms and amplitudes.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: current_driven_rc.expected.json
Iin 0 out SIN(0 .001 1k)
R1 out 0 1k
C1 out 0 1u
.hb 1k 4
.end
