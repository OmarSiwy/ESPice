* LRM 4.6.4.6 noise coefficient: 2*white_noise(P) contributes 4P
* Expected results: noise_va_coeff.expected.json
.hdl "va_noise.assets/noiseless_res.va"
.hdl "va_noise.assets/coeff_res.va"
Vin in 0 DC 0 AC 1
Ns in out noiseless_res
Nt out 0 coeff_res
.noise v(out) Vin lin 2 1000 2000
.end
