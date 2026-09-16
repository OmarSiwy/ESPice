* Logarithmic noise sweep cannot include zero.
* Expected results: noise_zero_frequency.expected.json
Vin in 0 1
R1 in out 1k
R2 out 0 1k
.noise v(out) Vin dec 10 0 100
.end
