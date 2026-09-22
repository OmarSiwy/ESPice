* A09: an analog initial block runs ONCE per analysis, at system initialization
* -- not per timepoint, not per solve attempt, not per Newton iterate, and not a
* second time for the transient's own initial DC solve.
* N2 forces rejected-and-retried steps so re-entry is exercised.
* LRM 5.2.1 ("executed once for each analysis"), 8.2 (initialization order).
* Expected results: a09_analog_initial_once.expected.json
.hdl "a09_analog_initial_once.assets/a09_initial_once.va"
.hdl "a09_analog_initial_once.assets/a09_cross_rejector.va"
N1 ini 0 a09_initial_once
R1 ini 0 1k
N2 rej 0 a09_cross_rejector
.tran 0.05 1.0
.end
