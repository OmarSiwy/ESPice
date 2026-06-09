# Oscillator Phase Noise (`.phasenoise`)

Phase noise of an autonomous oscillator by the perturbation projection
vector (PPV), the nonlinear-perturbation method of Demir, Mehrotra and
Roychowdhury (IEEE TCAS-I 47(5), 2000) and HSPICE's `.PHASENOISE`
METHOD=0. Built on the autonomous HB of
[pss-shooting-harmonic-balance.md](pss-shooting-harmonic-balance.md).

## 1. Mathematical specification

A small current b(t) injected into an oscillator moves it along its orbit
rather than off it, in the long run: x(t) ≈ x_s(t + α(t)) with

$$
\frac{d\alpha}{dt} = v_1(t + \alpha)^{\mathsf T} b(t),
$$

v₁ the T-periodic PPV. For white sources b = B(t)ξ(t) (ξ unit-intensity,
so a source with one-sided density S contributes √(S/2)), α is a random
walk with diffusion constant

$$
c = \frac{1}{T}\int_0^T \sum_s \big(v_{1,p_s}(t) - v_{1,n_s}(t)\big)^2 \frac{S_s(t)}{2}\,dt,
$$

and the single-sideband phase noise at offset f_m is the Lorentzian

$$
\mathcal L(f_m) = \frac{f_0^2\, c}{\pi^2 f_0^4 c^2 + f_m^2}.
$$

**The PPV from the HB Jacobian.** The HB residual F(X, ω) of the
oscillator has J = ∂F/∂X singular along the time-shift direction X′. With
a synchronous perturbation B added to the residual, the perturbed solution
satisfies J δX + (∂F/∂ ln ω) δ(ln ω) = −B, and the left null vector y of J
turns that into δ(ln ω) = −yᵀB / (yᵀ ∂F/∂ ln ω). The autonomous Newton
Jacobian J_ω is J with the osc node's sin₁ column replaced by ∂F/∂ ln ω.
Solving J_ωᵀ y = e_ω gives (J ᵀy)_j = 0 for every j ≠ ω, and yᵀJX′ = 0 with
X′_ω ≠ 0 forces the last component to 0 as well. So y is the left null
vector, already normalized to yᵀ ∂F/∂ ln ω = 1, from one transposed solve
of the final Newton factor. A constant perturbation drifts the phase at
dα/dt = δω/ω = (1/T)∫v₁ᵀb dt; matching harmonic by harmonic in HB's
[dc, cos_h, sin_h] amplitude convention gives

$$
v_1(t) = -\Big(y_{dc} + 2\sum_h y_{c,h}\cos h\omega t + y_{s,h}\sin h\omega t\Big).
$$

## 2. Flow explanation

`src/analysis/pss/phasenoise.zig`:

1. `hb.solveOscillator`: the autonomous shooting orbit seeds HB, HB solves
   the spectrum and f0, and on convergence it builds J_ω once more and
   returns y (`solveSpectrum`'s `ppv`).
2. `diffusion`: `hb.orbit` samples both the orbit and v₁ on 64 points (a
   power of two covering 2(2K+1)); `collectNoiseSources` at every sample
   gives S_s(t_k); c is the sample mean of Σ_s (v_p − v_n)² S_s/2.
3. Rows (frequency offset, `phnoise` in dBc/Hz).

Card: `.phasenoise v(out) sweep [f0 [K]]`. Without f0 the oscillator is the
deck's `.hbosc` card (tone guess, K, osc node), as in HSPICE, where
`.PHASENOISE` requires an `.HBOSC`. With f0, v(out) is the phase node.

## 3. Verification

`phasenoise/lc_oscillator`: a Van der Pol LC tank (L = 25.33 µH, C = 1 nF,
R = 10 kΩ, noiseless cubic conductance g₁ = 7e-4, g₃ = 8e-4, so A = 1 V).
For a sinusoidal orbit v₁ = −sin(ω₀t)/(C A ω₀) at the tank, and
𝓛(f_m) = kT / (R C² A² (2π f_m)²), the Hajimiri-Lee result with
Γ_rms² = 1/2. At 1 kHz the analytic value is −139.789 dBc/Hz; ESPice gives
−139.781 dBc/Hz (0.009 dB), and every offset of the sweep carries the same
difference. The oracle allows 0.1 dB. The residual is the orbit's O(ε²)
distortion (ε = 0.095): the fundamental is 1.00007 V, the third harmonic
1.2%.

## 4. Divergences and ceilings

- White sources only. A flicker source needs Demir's colored-noise
  extension, whose spectrum is not one Lorentzian; its 1/f part is dropped
  (a `ponytail:` comment in `phasenoise.zig`). HSPICE METHOD=0 includes it.
- METHOD=1 (periodic AC about the oscillator) and METHOD=2 (broadband) are
  not implemented, nor CARRIERINDEX, LISTFREQ, LISTSOURCES or the jitter
  outputs. `.ACPHASENOISE` is not implemented.
- The HB oscillator is seeded by an autonomous shooting PSS, not by
  HSPICE's probe-voltage search.
- Dense HB Jacobian: O((n(2K+1))²) memory, the same ceiling as `.hb`.

## Solvers used

| Phase | Impl |
|---|---|
| Autonomous shooting seed | `pss.solve` with `osc_node` |
| Autonomous HB Newton and the transposed PPV solve | `dense_lu.factorize`, `solveFactoredT` |

**Sources**: Demir, Mehrotra, Roychowdhury, "Phase noise in oscillators: a
unifying theory and numerical methods for characterization", IEEE TCAS-I
47(5):655-674, 2000 (the Lorentzian and c; not re-fetched for this page).
Hajimiri and Lee, IEEE JSSC 33(2), 1998 (the LC closed form). The HB
left-null-vector construction above is derived here.
