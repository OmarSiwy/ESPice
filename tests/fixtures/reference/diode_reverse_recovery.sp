* Diode reverse recovery and stored charge
* KNOWN GAP: diode transit-time charge is absent from the current diode model.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: diode_reverse_recovery.expected.json
Vin in 0 PULSE(-1 1 1u 10n 10n 2u 5u)
R1 in out 100
D1 out 0 dm
.model dm D(is=1e-14 rs=1 cjo=10p tt=100n)
.tran 1n 10u 0 1n
.options reltol=1e-6 abstol=1e-12 vntol=1e-8 method=gear temp=27 tnom=27
.end
