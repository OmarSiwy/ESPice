* A09: at a converged point the $limit() return value IS the value of the
* access function reference. LRM 9.17.3: "When the simulator has converged, the
* return value of the $limit() function is the value of the access function
* reference, within appropriate tolerances", enforced by "On any iteration
* where the output value is not the same as the value of the access function
* (within appropriate tolerances), the simulator is prevented from terminating
* the iteration" and by the user function's obligation to call
* $discontinuity(-1) (LRM 9.17.1, 9.17.3).
*
* The contribution uses the LIMITED value, so every converged point has
* vlim = 1 + 0.5*t. The rawfile records V(p,n). The two agree only if the
* solver honoured the sentence above, so v(lim) = 1 + 0.5*t is that sentence
* and nothing else. A solver that "may simply choose to have $limit() return
* the value of its first argument" -- 9.17.3, expressly permitted -- passes.
*
* Tolerance is rtol 1e-3 / atol 1e-6, and the digits are deliberately NOT
* tighter. "Within appropriate tolerances" is left to the implementation; LRM
* 8.3.3 gives only the shape -- |v(j) - v(j-1)| < reltol*max(|v(j)|,|v(j-1)|)
* + abstol -- and prints reltol "typically ... 0.001". A tighter band would red
* a conforming solver that stops at its own reltol. 1e-3 still fails a solver
* that terminates while the limiter is clamping: that V(p,n) is off by the
* clamp, up to 0.5 V on a 1-2 V signal, 250x to 500x the band. Measured today
* this host lands 5.7e-8 from the root, i.e. 1/20000 of the band.
*
* CORRECTED after review. An earlier revision of this deck asserted that $limit
* "may defer convergence; it may not move the root and it may not cost the
* solver its step". Only the first clause is in 9.17.3. 9.17.3 makes the
* simulator "responsible for determining if limiting should be applied and what
* the return value is on a given iteration" and 8.3.2 leaves the interval
* between the time points to the simulator, so iteration economy and step
* economy are implementation-defined and no digits are written for them. The
* same revision described its limiter as the LRM's -- the LRM's only $limit
* example is spicepnjlim -- and SPEC.md claimed ".op on this model gives
* exactly 1.0". It does not: the converged root at t = 0 measures
* 1.0000000574268284, 5.74e-8 high, which is one reason the band is 1e-3/1e-6
* and not the 1e-9 the linear decks in this row use. See the .va header for the
* model corrections, including the removal of the $simparam("iteration") seed
* reset that made this deck unsolvable, and for the codegen defect that
* dictates the limiter's branch-free spelling.
* LRM 9.17.3 ($limit), 9.17.1 ($discontinuity), 8.3.3 (convergence criteria).
* Expected results: a09_limit_root_transient.expected.json
.hdl "a09_limit_root_transient.assets/a09_limit_ramp.va"
N1 lim 0 a09_limit_ramp
.tran 0.1 2.0
.end
