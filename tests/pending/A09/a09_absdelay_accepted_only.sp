* A09: the delay-line history is accepted-step state. A sample pushed on a
* rejected attempt is a sample at a time that never happened, so the delayed
* waveform must not depend on how many attempts were rejected. N2 forces four
* rejection bursts; the delayed ramp must stay exact.
* LRM 4.5.7 (absdelay), 4.5.15 (no state history prior to t == 0), 8.4.7.
* Expected results: a09_absdelay_accepted_only.expected.json
.hdl "a09_absdelay_accepted_only.assets/a09_delayed_ramp.va"
.hdl "a09_absdelay_accepted_only.assets/a09_cross_rejector.va"
N1 dl 0 a09_delayed_ramp
R1 dl 0 1k
N2 rej 0 a09_cross_rejector
.tran 0.05 1.0
.end
