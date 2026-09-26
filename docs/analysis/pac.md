# Periodic AC (PAC)

LPTV transfer functions via the harmonic conversion matrix. Implemented
(simplified PSS front end); Spectre-PAC equivalent in structure.

## 1. Mathematical specification

Linearize about the periodic orbit $v_L(t)$ (period $T_L = 1/f_{LO}$):
$G(t), C(t)$ periodic (see [periodic-noise.md](periodic-noise.md) §1).
Expand them in Fourier series $G(t) = \sum_m G_m e^{jm\omega_{LO}t}$,
$C(t) = \sum_m C_m e^{jm\omega_{LO}t}$. A small input at $f_{in}$ produces
output at every sideband $f_p = f_{in} + m_p f_{LO}$; collecting the
sideband phasors $X_q$ ($m_q \in [-M, M]$) gives the **conversion-matrix
system**: block $(p, q)$ couples sideband $q$ into sideband $p$ through
the $(m_p - m_q)$-th harmonic of the operating point:

$$
\sum_{q} \big[\, G_{m_p - m_q} + j\omega_p\, C_{m_p - m_q} \big]\, X_q = B_p,
\qquad \omega_p = 2\pi (f_{in} + m_p f_{LO}),
$$

a dense $n(2M{+}1)$ complex system per input frequency. The excitation
$B$ sits in the $m=0$ block (input applied at $f_{in}$); the solution's
block $p$ is the transfer to sideband $m_p$: one solve yields the full
set of frequency-translating transfer functions $H_{m}(f_{in})$ (Kundert
rf-sim.pdf eqs. 48-49: "with periodically-varying linear systems there are
an infinite number of transfer functions... each represents a different
frequency translation"). Truncation to $|m| \le M$ requires
$N_{\text{samples}} \ge 2(2M{+}1)$ time samples so the needed harmonics of
$G, C$ are alias-free.

This is a *true* LPTV solve (unlike pnoise's current frozen-time
averaging): sideband coupling is exact within the harmonic truncation.

## 2. Flow explanation

`src/analysis/pss/pac.zig analyze()`:

1. **PSS (simplified)**: brute-force settling, `pss_periods - 1` periods
   of frozen-time quasi-static Newton solves at `n_time_samples` per
   period (no shooting Newton; adequate when the orbit's transient decays
   within the settle window). Every settle and sample evaluation runs under
   `analysis("tran")` (`setSimState(.{ .kind = .tran })`), because
   Verilog-A sources follow their time waveform only in a transient
   analysis (§4.6.1); under the DC state they would hold their DC value and
   the LO would never move. $dt$ stays 0, so the settling is quasi-static.
   (Commit `57d0d44`; pnoise does the same. The LTI fixtures did not change
   bytes.)
2. **Sampling**: over the final period, one `eval` per sample; $G(t_k)$ and
   $C(t_k)$ are stored over the nnz pattern, slot-major with samples
   contiguous, not as dense $n \times n$ matrices (commit `47e9b03`: a diode
   mixer with a 40-stage RC ladder at `.pac 1k dec 3 10 100` went from
   146.9 to 132.8 ms under hyperfine on a loaded machine and from 16.3 to
   11.6 MB peak RSS; callgrind could not run it because valgrind lacks the
   GFNI instructions LLVM emits for the FFT's `@bitReverse`).
3. **Harmonic decomposition**: FFT each slot's time series; normalize by
   $N$ to get the $\hat G_m, \hat C_m$ coefficients per slot.
4. **Sweep**: per input frequency, assemble the $(2M{+}1)n$ conversion
   matrix in stacked-real form ($2\times$ blocks $[\Re, -\Im; \Im, \Re]$),
   unit excitation in the $m{=}0$ block at the source node, dense LU
   solve, read the probe node in every sideband block.

Knobs: `f_lo`, `n_harmonics` ($M$), `n_time_samples` (power of 2,
$\ge 2(2M{+}1)$), sweep triple, PSS settle knobs. Failure: singular
conversion matrix errors the sweep; PSS quality is the silent risk
(settling too short gives a wrong $G_m$), and the shooting-Newton PSS
(`pss.zig`) is the front-end upgrade. Multi-probe B-source expressions
(two `V()` pairs) are rejected with `UnsupportedBsourceExpression` rather
than computed wrong (`pac/ideal_multiplier_*`).

## 3. Solver needs / pseudo-code sketch

```
pac(ckt, f_lo, M, sweep):
    settle (P-1) periods of quasi-static newton under analysis("tran")
    sample final period: G, C per nnz slot
    Ghat_m, Chat_m = FFT over samples, per slot
    for f_in in sweep:
        for p, q in sidebands:  A[p][q] = Ghat[p-q] + j*w_p*Chat[p-q]
        solve dense A X = e[m=0, src]                    # (2M+1)n complex
        H_m(f_in) = X[block m][probe]
```

**Solver needs**: per-frequency dense complex solve of size $n(2M{+}1)$ -
$O((nM)^3)$; the scalable route is block-structured: GMRES with the
conversion-matrix apply done as FFT·(time-domain multiply)·IFFT per Krylov
vector and a block-diagonal $(G_0 + j\omega_p C_0)$ preconditioner
(identical machinery to Krylov-HB in
[pss-shooting-harmonic-balance.md](pss-shooting-harmonic-balance.md) §4);
sparse per-block factors would come from the KLU pipeline. Not implemented:
the conversion matrix is dense today, and there is no GPU path.

## Solvers used

| Phase | Solver doc | Impl |
|---|---|---|
| PSS settle solves | [newton-raphson-convergence.md](../solvers/newton-raphson-convergence.md), [klu-pipeline.md](../solvers/klu-pipeline.md) | `converger.run` per sample |
| Harmonic decomposition | none (support kernel) | `src/solver/fft.zig` |
| Conversion-matrix solve | none (dense path today); Krylov upgrade per above | `src/solver/dense_lu.zig factorizeSolve` |

---

**Sources fetched**: Kundert rf-sim.pdf (fetched; LPTV/sideband transfer
structure, eqs. 48-49; PAC/PXF duality §"periodic AC"). Conversion-matrix
algebra: derived, not source-verified (standard LPTV/harmonic-transfer-
matrix result; matches the implemented code).

**Verification**: §1 conversion-matrix structure and truncation bound:
verified against `pac.zig`; the PSS front-end simplification is flagged in
§2. §2/§3: transcribed from source.

**Our implementation**: `src/analysis/pss/pac.zig`. Fixtures:
`tests/fixtures/pac/`.
