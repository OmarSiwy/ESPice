* LRM 4.6.4.6 one noise source on two branches, anti-correlated
* Expected results: noise_va_correlated.expected.json
.hdl "va_noise.assets/noiseless_res.va"
.hdl "va_noise.assets/corr_res.va"
Vin in 0 DC 0 AC 1
Ns in a noiseless_res
Nc a b corr_res
.noise v(a,b) Vin lin 2 1000 2000
.end
