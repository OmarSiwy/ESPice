* Verilog-A transition started by a cross event, behind a tank that forces
* LTE and state rejections, each of which must revert the transition history
* Expected results: veriloga_transition_reject.expected.json
.hdl "veriloga_transition_reject.assets/va_cmp.va"
Vin in 0 PWL(0 0 10u 1)
N1 in out va_cmp
R1 out a 1
L1 a b 1u
C1 b 0 100p
.tran 100n 10u
.end
