* reltol=0 leaves no step a transient can take; the card fails (#150)
* Expected results: options_reltol_zero.expected.json
V1 in 0 pulse(0 1 0 1n 1n 1u 2u)
R1 in out 1k
C1 out 0 1n
.options reltol=0
.tran 10n 2u
.end
