* Two sensors of one V source each read its whole current (#74).
* Expected results: sensed_vsource_two_sensors.expected.json
* i(V1) = -V1/R1 = -1 mA. F1 gives v(2) = 2 V1 and H1 gives v(3) = -V1;
* splitting the current between them halves both, and before the fix
* the AC matrix was singular.
V1 1 0 DC 1 AC 1
R1 1 0 1k
F1 2 0 V1 2
R2 2 0 1k
H1 3 0 V1 1k
R3 3 0 1k
.op
.ac dec 1 1k 100k
.end
