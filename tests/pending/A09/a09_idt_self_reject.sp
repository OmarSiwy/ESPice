* A09: the instance that CAUSES the rejection keeps its own accepted-time state.
* One module owns both the cross() latch (which forces the retry) and the idt
* accumulator, so the retry re-enters the same instance that triggered it.
* LRM 4.5.4, 4.5.15, 5.10.3.1, 8.4.7 ("Advance of time in an analog algorithm",
* third bullet).
*
* Sample times are the plateau midpoints 0.05, 0.25, 0.5, 0.75, 0.95, not the
* 0.2/0.4/0.6/0.8 grid an earlier revision used. The value is a staircase with
* 1e-3 risers at t = 0.125, 0.375, 0.625, 0.875, and the correctness harness
* (tests/test_correctness.zig, `sample`) linearly interpolates between the two
* bracketing ACCEPTED rows. Asserting at rtol 1e-9 only 0.025 away from a riser
* relied on the current step controller keeping avg_dt at 6.8e-3; a legal
* controller taking one 0.05 step there straddles the riser and the
* interpolated value is wrong by up to 1e-3. The nearest riser to any sample
* time is now 0.075 away, ~11 steps at today's avg_dt and still clear of a
* controller ten times coarser.
* Expected results: a09_idt_self_reject.expected.json
.hdl "a09_idt_self_reject.assets/a09_idt_latched.va"
N1 out 0 a09_idt_latched
R1 out 0 1k
.tran 0.05 1.0
.end
