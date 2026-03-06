* X01 pending fixture: LTRA run whose LIVE history depth exceeds the native
* 8192-entry capacity (ltra_native.zig:61 CAP=8192).
*
* CORRECTED AFTER REVIEW.  The previous version of this deck drove the line with
* a PULSE and claimed "compactrel/compactabs are set to 1e-30 so the straight-line
* compaction can never hide the overflow".  That claim is FALSE, and the fixture
* it justified gated nothing.  ltra_native.straightLineCheck (:277) is
*   quad1=(|y2|+|y1|)/2*|x2-x1|, quad2=(|y3|+|y2|)/2*|x3-x2|,
*   quad3=(|y3|+|y1|)/2*|x3-x1|,
*   accept if (quad1+quad2)*reltol + abstol > |quad3-quad1-quad2|
* On an exactly flat, evenly spaced plateau (y1=y2=y3=y, x2-x1=x3-x2=h) this is
* quad1=quad2=|y|h, quad3=2|y|h, so the right-hand side is IDENTICALLY ZERO and
* the test accepts for ANY positive reltol or abstol.  Every waveform in a
* step-driven matched deck is a flat plateau, so compact() succeeded on every
* overflow, the history never approached capacity, and the deck passed whatever
* CAP was compiled in -- including CAP=8.  Tolerances cannot disable compaction;
* only a curved waveform can.  So the waveform, not the tolerance, is the fix.
*
* This version drives the same line with a sine, which is curved everywhere the
* plateau was flat:
*   Td  = len*sqrt(l*c) = 2 m * 5 ns/m = 10 ns, forced dt = 1 ps (tmax = 1 ps),
*   so the far-end value depends on a sample 10000 accepted points back, 1808
*   past the 8192 bound.
*   compactrel = compactabs = 1e-30 now do what the old header wrongly claimed
*   of them on a plateau.  On a 1 ps triple of 0.5*sin(2*pi*250e6*t) the residual
*   |quad3-quad1-quad2| is of order h*(h^2/8)*|y''| = 1e-12*1.5e-7 = 1.5e-19,
*   against a right-hand side of (quad1+quad2)*1e-30 + 1e-30 ~ 1e-30 -- eleven
*   orders too small, so the test REJECTS.  (The honest exception: triples
*   straddling a zero crossing, where y'' -> 0, are genuinely collinear and are
*   still compacted.  Those are a vanishing fraction of the 10000, which is why
*   the deck still overflows.)  compact() therefore falls through to its "drop
*   the oldest interior point" branch (:884, :895) -- the pure capacity overflow
*   this fixture is named for.
*   The deck also fails at the DEFAULT 1e-3/1e-12 (compaction distortion rather
*   than pure discard, max v(b) error 0.917 V at t = 21 ns), so it is not tuned
*   to one branch.
*
* Exact answer.  Z0 = sqrt(250n/100p) = 50 ohm, Rs = RL = Z0, so GammaS = GammaL
* = 0 and the line is a pure attenuated delay; alpha*Td = (r/2l)*Td = 2e-8 Np is
* below every tolerance here.  With f = 250 MHz the period is 4 ns and Td = 10 ns
* is exactly 2.5 periods, so the delay is an exact half-period inversion:
*   v(a)(t) = 0.5*sin(2*pi*f*t)
*   v(b)(t) = 0.5*sin(2*pi*f*(t-Td)) = 0.5*sin(2*pi*f*t - 5*pi) = -v(a)(t), t > Td
*             0                                                            t < Td
* Hand-derived samples (accepted index = t/1 ps; f*t at 250 MHz in cycles):
*   t =  9.9 ns  f*t = 2.475  v(a) = 0.5*sin(0.95*pi) = +0.078217233  v(b) = 0
*   t = 13.0 ns  f*t = 3.25   v(a) = +0.5   v(b) = -0.5
*   t = 15.0 ns  f*t = 3.75   v(a) = -0.5   v(b) = +0.5
*   t = 17.0 ns  f*t = 4.25   v(a) = +0.5   v(b) = -0.5
*   t = 21.0 ns  f*t = 5.25   v(a) = +0.5   v(b) = -0.5
*   t = 23.0 ns  f*t = 5.75   v(a) = -0.5   v(b) = +0.5
*   t = 24.5 ns  f*t = 6.125  v(a) = 0.5*sin(pi/4) = +0.353553391  v(b) = -0.353553391
* Sampling.  An earlier draft of this header claimed "every sample lands exactly
* on the 1 ps accepted grid, so no interpolation".  Measured, that is false: the
* forced step is a ceiling, not a lattice, and the accepted times drift up to
* 0.37 ps off the multiples of 1 ps on the host and 0.28 ps on ngspice-44.2.  The
* runner's `samples` mode interpolates linearly between accepted points, whose
* error on this waveform is bounded by (h^2/8)*|v''| = (1e-24/8)*0.5*(2*pi*f)^2
* = 1.54e-7 V; the observed residual against the closed form is 1.2e-7 V.  The
* 5e-6 atol below is 32x that bound and 6000x below the 0.9 V defect.
* The 9.9 ns row gates "nothing published before Td"; the five +-0.5 rows gate
* the deep lookback -- a history that discarded still-live entries cannot even
* get the SIGN right, which is what makes this fixture fail in kind and not by a
* tolerance.
*
* Measured, not assumed (checkpoint binary; see SPEC.md "Reproduction"):
*   ngspice-44.2 on this exact netlist agrees with the seven hand rows to 1.4e-7.
*   The host is wrong at v(b) by up to 0.919 V on a 0.5 V amplitude, and the
*   sign is wrong at every row after Td: it returns -0.419315 at t = 23 ns where
*   +0.5 is required (the worst row, error 0.919) and +0.297982 at t = 13 ns
*   where -0.5 is required (error 0.798).
*   The identical deck at tmax = 10 ps (2507 accepted points, UNDER the bound)
*   agrees with the closed form to 1.22e-5, of which 1.54e-5 is the allowed
*   10 ps interpolation bound -- i.e. indistinguishable from exact, which
*   isolates the defect to the capacity and not to the model or the source.
* Expected results: ltra_tran_long_run_past_8192.expected.json
Vin in 0 SIN(0 1 250meg)
Rs in a 50
O1 a 0 b 0 lline
RL b 0 50
.model lline LTRA(r=1e-6 l=250n g=0 c=100p len=2 rel=1 compactrel=1e-30 compactabs=1e-30)
.tran 1p 25n 0 1p
.end
