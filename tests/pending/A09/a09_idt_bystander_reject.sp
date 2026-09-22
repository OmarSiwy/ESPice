* A09: a step rejection raised by ANOTHER device must not disturb this one's
* accepted-time operator state. N2 resolves a cross() event, which costs the
* host a rejected-and-retried step at t = 0.125, 0.375, 0.625 and 0.875; N1 is
* an innocent bystander whose idt(1.0, 0) must still read v(out) = t.
* LRM 4.5.4 (idt closed form), 4.5.15 (operator state), 8.4.7 (accept/reject).
* Expected results: a09_idt_bystander_reject.expected.json
.hdl "a09_idt_bystander_reject.assets/a09_idt_ramp.va"
.hdl "a09_idt_bystander_reject.assets/a09_cross_rejector.va"
N1 out 0 a09_idt_ramp
R1 out 0 1k
N2 rej 0 a09_cross_rejector
.tran 0.05 1.0
.end
