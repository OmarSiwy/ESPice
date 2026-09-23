* AM takes ngspice's argument order: VO VMO VMA FM FC TD PHASEM PHASEC (#73).
* Expected results: source_am_ngspice.expected.json
* v(a) = (0.5 + 1 sin(2 pi 100k t' + 30deg)) sin(2 pi 1meg t' + 45deg),
* t' = t - 1u, and 0 before 1 us.
V1 a 0 AM(0 0.5 1 100k 1meg 1u 30 45)
R1 a 0 1k
.tran 10n 12u
.end
