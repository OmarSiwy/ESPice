* Negative-feedback return ratio, sign and gain
* KNOWN GAP: STB dispatch is rejected and does not yet implement the specified return-ratio measurement.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: negative_feedback_gain_100.expected.json
Vin in 0 0
Rin in sum 1k
Eamp amp 0 0 sum 100
Vprobe amp fb 0
Rf fb sum 9k
Rl fb 0 1k
.stb Vprobe dec 4 1 1meg
.end
