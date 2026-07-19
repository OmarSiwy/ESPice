* LRM 4.6.4.6 one noise source on two branches, anti-correlated
* KNOWN GAP: rows sharing a contract `source` id are summed as independent powers: abi.NoiseSource carries neither `source` nor a signed coeff (and the to-ground rows read zero transfer).
* Expected results: noise_va_correlated.expected.json
.hdl "va_noise.assets/noiseless_res.va"
.hdl "va_noise.assets/corr_res.va"
Vin in 0 DC 0 AC 1
Ns in a noiseless_res
Nc a b corr_res
.noise v(a,b) Vin lin 2 1000 2000
.end
