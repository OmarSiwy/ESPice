* A09 control case: idt(1.0, 0) is the unit ramp, v(out) = t exactly.
* LRM 4.5.4 Table 4-18 gives the closed form; 4.5.15 fixes the operator's state
* to the accepted-time lifetime. No rejection is provoked here, so this deck
* isolates "the accumulator advances once per accepted step" from the
* rejection/retry path that a09_idt_{bystander,self,lte}_* exercise.
* Expected results: a09_idt_ramp_clean.expected.json
.hdl "a09_idt_ramp_clean.assets/a09_idt_ramp.va"
N1 out 0 a09_idt_ramp
R1 out 0 1k
.tran 0.05 1.0
.end
