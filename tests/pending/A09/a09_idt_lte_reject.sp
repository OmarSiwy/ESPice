* A09: rejection from the INTEGRATOR, not from an event. The Rs/C1 branch driven
* at 20 Hz makes the local-truncation-error controller reject and retry steps
* throughout the run; N1 carries no charge and must still read v(out) = t.
* Same clauses as the cross-driven decks, different rejection origin, so the two
* retry paths are pinned separately.
* LRM 4.5.4, 4.5.15, 8.3.2 (time discretization / step control), 8.4.7.
* Expected results: a09_idt_lte_reject.expected.json
.hdl "a09_idt_lte_reject.assets/a09_idt_ramp.va"
N1 out 0 a09_idt_ramp
R1 out 0 1k
Vin in 0 SIN(0 1 20 0 0)
Rs in a 1k
C1 a 0 1u
.tran 0.02 1.0
.end
