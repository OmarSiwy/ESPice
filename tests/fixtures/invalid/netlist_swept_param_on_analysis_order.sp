* The same card before its .step is refused too, not run at the nominal (#63).
* Expected results: netlist_swept_param_on_analysis_order.expected.json
.param tst=1u
V1 a 0 1
R1 a 0 1k
.tran 1n {tst}
.step param tst list 1u 2u
.end
