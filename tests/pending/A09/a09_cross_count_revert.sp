* A09: a model side effect staged by a REJECTED attempt must be rolled back, and
* applied exactly once when a step is finally accepted. The held variable counts
* rising crossings, and KCL makes the node read the count back as volts.
* LRM 5.10.3.1: "If dir is +1, the event and timestep control only occur on
* rising edge transitions of the signal", and "The event shall occur after the
* threshold crossing, and while the signal remains in the box defined by actual
* crossing and expr_tol and time_tol". The expression has exactly four rising
* zero crossings in (0, 1], so exactly four events are licensed; a fifth event
* is licensed by no crossing and a missing one contradicts "shall occur".
* LRM 8.4.7, "Advance of time in an analog algorithm", third bullet: "Having
* calculated the solution for a given time, the analog engine can either accept
* or reject that solution; it cannot calculate a solution for a future time
* until it has accepted the solution for the current time."
* LRM 8.3.3 (the first-iteration values "do not satisfy Kirchhoff's Laws", so an
* iterate is not a solution and cannot license an event either).
*
* WITHDRAWN: earlier revisions of this deck cited 8.4.7's "they can be rejected
* along with the solution, if it is rejected". That sentence sits under 8.4.7's
* "Analog to digital events" heading and is conditioned on "until they are
* consumed by the digital engine". This deck has no digital engine, so the
* sentence does not reach it. The claim now belongs to plan row M02, whose
* clause list already spans 8.4.1-8.4.7; it can come back to A09 only in a deck
* that actually has a digital consumer for the cross event.
* Expected results: a09_cross_count_revert.expected.json
.hdl "a09_cross_count_revert.assets/a09_cross_rejector.va"
N1 rej 0 a09_cross_rejector
.tran 0.05 1.0
.end
