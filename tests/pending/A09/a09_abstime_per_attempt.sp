* A09: $abstime published per SOLVE ATTEMPT, read back at the ACCEPTED point.
* N2 forces rejected-and-retried steps at the four crossings; every accepted row
* must still carry v(ta) == t, with no residue of a rejected trial time.
* LRM 9.10 ($abstime), 8.4.7 (accept/reject ordering).
* Expected results: a09_abstime_per_attempt.expected.json
.hdl "a09_abstime_per_attempt.assets/a09_abstime_source.va"
.hdl "a09_abstime_per_attempt.assets/a09_cross_rejector.va"
N1 ta 0 a09_abstime_source
R1 ta 0 1k
N2 rej 0 a09_cross_rejector
.tran 0.05 1.0
.end
