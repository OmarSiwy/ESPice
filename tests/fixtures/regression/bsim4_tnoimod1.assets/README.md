BSIM4 DC topology regression: `tnoimod=1`, `rdsmod=0`, `nrd=nrs=0`.
Both transistor polarities must conduct; the broken implementation returned zero.

ngspice 44.2 reference currents:

- `i(vdn) = -1.8044732123927052 mA`
- `i(vdp) = +0.7664838086544653 mA`

Run the strict comparison with
`python3 benchmark/check_fixtures.py --category regression --reference --engine PATH`.
The default relative tolerance is 0.1%. The topology correction alone leaves
an existing 1.1–1.3% default-model current mismatch, also present at `tnoimod=0`.
The engine unit test isolates the repaired topology by comparing modes 0 and 1;
this fixture keeps the broader ngspice accuracy failure visible.
