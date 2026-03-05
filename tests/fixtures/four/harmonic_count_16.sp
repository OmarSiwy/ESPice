* Honor the requested Fourier harmonic count
* KNOWN GAP: Fourier extraction is currently capped at nine harmonics.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: harmonic_count_16.expected.json
Vin out 0 SIN(0 1 1k)
R1 out 0 1k
.tran .2u 5m 0 .2u
.four 1k v(out) 16
.end
