* Verilog-A noise generator to ground: I(p) <+ white_noise(P)
* Expected results: noise_va_ground.expected.json
.hdl "va_noise.assets/noiseless_res.va"
.hdl "va_noise.assets/ground_res.va"
Vin in 0 DC 0 AC 1
Ns in out noiseless_res
Ng out ground_res
.noise v(out) Vin lin 2 1000 2000
.end
