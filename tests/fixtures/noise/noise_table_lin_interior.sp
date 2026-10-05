* LRM 4.6.4.3 noise_table: piecewise-linear PSD at tabulated and interior points
* Expected results: noise_table_lin_interior.expected.json
* Origin: VerA tests/fixtures/ch04_expressions/a06_noisetables_a06_ntab_lin_interior.sp
.hdl "va_noise.assets/noiseless_res.va"
.hdl "va_noise.assets/ntab_lin.va"
Vin in 0 DC 0 AC 1
Ns in out noiseless_res
Nt out 0 ntab_lin
.noise v(out) Vin lin 9 1000 9000
.end
