* A V source an H card senses keeps its transient waveform (#103, #106).
* Expected results: sensed_vsource_tran.expected.json
* v(1) = V1 across R1; H1 reads 1k i(V1) = -V1, so v(2) = -v(1).
V1 1 0 PULSE(0 1 100n 10n 10n 400n 1u)
R1 1 0 1k
H1 2 0 V1 1k
R2 2 0 1k
.tran 10n 1u
.end
