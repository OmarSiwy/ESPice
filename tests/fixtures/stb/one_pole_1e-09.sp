* Frequency-dependent loop gain and feedback loading
* KNOWN GAP: STB dispatch is rejected and does not yet implement the specified return-ratio measurement.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: one_pole_1e-09.expected.json
Vin in 0 0
Rin in sum 1k
Rf fb sum 9k
Rfilter sum filt 1k
Cfilter filt 0 1e-09
Eamp amp 0 0 filt 100
Vprobe amp fb 0
Rl fb 0 1k
.stb Vprobe dec 4 1 1meg
.end
