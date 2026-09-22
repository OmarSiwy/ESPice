* X01 pending fixture: accepted LTRA history must survive rejected trial steps.
*
* CORRECTED AFTER REVIEW.  The previous deck was driven by a PULSE, so every
* asserted value sat on a flat plateau and every number it asserted (0.5, 0.75)
* was numerically identical to ltra_tran_mismatched_load.  That is not an
* oversight in sampling, it is fatal to the claim: a history buffer whose entries
* are all the SAME number cannot be observed to have been corrupted by a rejected
* trial step, because writing a trial value into it changes nothing.  The deck
* asserted a plateau height set by reflection algebra and called it evidence
* about history integrity.
*
* The source is now a sine, so no two history entries are equal and the far-end
* value at time t is a *specific* interior sample, taken Td back, that cannot be
* reconstructed from any neighbour.  Same line and same mismatched load as
* ltra_tran_mismatched_load (Z0 = 50, Td = 10 ns, RL = 150), same 1 pF far-end
* capacitor and same reltol=1e-8 / vntol=1e-12 / abstol=1e-15 with no user tmax,
* which is what actually forces the LTE controller to shrink, reject and retry.
*
* Evidence that the tolerances really change the grid, measured on this exact
* deck with the checkpoint binary (see SPEC.md "Reproduction"): 2966 accepted
* points at reltol=1e-8 against 2258 with the `.options` line deleted, and the
* asserted values are the same at both settings to 5.4e-6.  Both counts are well
* under the 8192 history bound, so this fixture is about trial-step containment
* only and does not overlap ltra_tran_long_run_past_8192.
*
* Closed form.  Rs = Z0 so GammaS = 0: the forward wave is exactly half the
* source, it reflects once at the load and is absorbed at the source end.  With
* f = 62.5 MHz (period 16 ns), w = 2*pi*f, s(t) = sin(w t):
*   ZL     = 1/(1/RL + jwCL) = 149.481332245 - 8.805177286j    (|wRLCL| = 5.9e-5)
*   GammaL = (ZL-Z0)/(ZL+Z0) = 0.499674778 - 0.022084534j
*   t < Td       v(b) = 0                     (nothing has arrived)
*   t > Td       v(b) = Im[0.5(1+GammaL) e^{-jwTd} e^{jwt}]
*   t < 2Td      v(a) = 0.5 s(t)              (incident only, no return yet)
*   t > 2Td      v(a) = Im[0.5(1 + GammaL e^{-2jwTd}) e^{jwt}]
* The load's own RC transient decays with tau = (RL||Z0)*CL = 37.5 ps, so the
* phasor form is exact to e^{-133} by the first sample after Td (15 ns).
* Sampled values (hand-evaluated from the two phasors above):
*   t =  5.0 ns  v(a) = +0.46193976625564337  v(b) =  0            (pre-Td gate)
*   t =  9.9 ns  v(a) = -0.33940037276647106  v(b) =  0            (pre-Td gate)
*   t = 15.0 ns  v(a) = -0.19134171618254436  v(b) = +0.6969851092378405
*   t = 21.0 ns  v(a) = +0.547346671383589    v(b) = -0.6885337239407996
*   t = 25.0 ns  v(a) = +0.04370362679965237  v(b) = -0.29715207031544805
*   t = 29.0 ns  v(a) = -0.547346671383589    v(b) = +0.6885337239407995
*   t = 33.0 ns  v(a) = -0.04370362679965148  v(b) = +0.29715207031544694
*   t = 39.0 ns  v(a) = +0.41793567386770003  v(b) = -0.6969851092378401
*   t = 44.0 ns  v(a) = -0.4889577329689854   v(b) = +0.5224070407899736
* The 15 ns row is the one the old deck could not express: Td < 15 ns < 2Td, so
* v(a) there must still be the pure incident -0.191342 while v(b) is already
* +0.696985.  A trial value leaking into the accepted history moves v(b) by order
* 0.1-0.9 V (see the sibling 8192 fixture for the same corruption measured), four
* orders above the 5e-5 band below; the band itself is set by the runner's own
* linear interpolation between 20 ps output points, (h^2/8)|v''| = 3.9e-6.
* The repeatability check additionally requires two runs of the same deck to agree.
* Measured, not assumed: the checkpoint binary reproduces all 18 values to 5.4e-6
* and an independent ngspice-44.2 run of this exact netlist to 5.3e-6 -- i.e. this
* fixture PASSES today and is a regression gate, not one of the row's failures.
* Expected results: ltra_tran_rejected_step_retry.expected.json
Vin in 0 SIN(0 1 62.5meg)
Rs in a 50
O1 a 0 b 0 lline
RL b 0 150
CL b 0 1p
.model lline LTRA(r=1e-6 l=250n g=0 c=100p len=2 rel=1)
.options reltol=1e-8 vntol=1e-12 abstol=1e-15
.tran 20p 45n
.end
