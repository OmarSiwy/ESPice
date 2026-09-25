* A swept parameter on an analysis card is refused, naming the card (#63).
* Expected results: netlist_swept_param_on_analysis.expected.json
* Nothing would re-read the .tran stop time per .step point.
.param tst=1u
V1 a 0 1
R1 a 0 1k
.step param tst list 1u 2u
.tran 1n {tst}
.end
