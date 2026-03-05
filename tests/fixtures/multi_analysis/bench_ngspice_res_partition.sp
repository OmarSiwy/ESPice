* Resistive partition with different ratios for AC/DC (Print V(2))
* Expected results: bench_ngspice_res_partition.expected.json
* Origin: benchmark/fixtures/ngspice/res_partition/circuit.sp

vin 1 0 DC 1V AC 1V
r1  1 2 5K
r2  2 0 5K ac=15k

.options noacct
.OP
.AC DEC 10 1 10K
.print ac v(2)
.END
