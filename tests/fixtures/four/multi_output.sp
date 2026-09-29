* .four f ov1 ov2: one Fourier table per output, as ngspice prints them.
* Oracle: analytic (ngspice 44.2 prints the same tables): v(a) is
* 1 V sin at 1 kHz, sine phase -90 deg in cosine reference; v(b) is v(a)/2
* plus 0.5 V DC.
* Expected results: multi_output.expected.json
va a 0 sin(0 1 1k)
vb c 0 1
r1 a b 1k
r2 b c 1k
.tran 2u 5m
.four 1k v(a) v(b)
.end
