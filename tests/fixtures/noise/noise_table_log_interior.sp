* LRM 4.6.4.4 noise_table_log: log-log interpolation, not linear, between knots
* Expected results: noise_table_log_interior.expected.json
* Origin: VerA tests/fixtures/ch04_expressions/a06_noisetables_a06_ntab_log_interior.sp
.hdl "va_noise.assets/noiseless_res.va"
.hdl "va_noise.assets/ntab_log.va"
Vin in 0 DC 0 AC 1
Ns in out noiseless_res
Nt out 0 ntab_log
.noise v(out) Vin lin 3 1000 3000
.end
