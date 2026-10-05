# Oscillator Phase Noise (`.phasenoise`, `.acphasenoise`)

Phase noise of an autonomous oscillator by the perturbation projection
vector (PPV), the nonlinear-perturbation method of Demir, Mehrotra and
Roychowdhury (IEEE TCAS-I 47(5), 2000) and HSPICE's `.PHASENOISE`
METHOD=0; by periodic noise about the orbit (METHOD=1); or both stitched
(METHOD=2). Built on the autonomous HB of
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

**Flicker sources.** A source m_s(t)·n(t), n of one-sided PSD 1/f^ef and
far slower than the period, drives dα/dt only through the period average
of v₁ times m_s = √(flicker_s(t)). Its two-sided density at f_m adds

$$
c_s(f_m) = \frac{\langle (v_{1,p}-v_{1,n})\,m_s \rangle^2}{2 f_m^{ef}}
$$

to c, and c(f_m) goes through the same Lorentzian. HSPICE documents
PHNOISE_LORENTZ=1 (the default) as a Lorentzian for every source; that
this is its exact colored-noise form is unconfirmed.

**METHOD=1.** The periodic noise density of the osc node at k·f0 + f_m
(the `.pnoise` sideband sum about the HB orbit, M = K sidebands) over
the carrier's mean-square amplitude A_k²/2: phase and amplitude noise
together. The conversion matrix is singular along the orbit's phase mode,
so close-in offsets lose accuracy; METHOD=0 is the close-in method.

**METHOD=2.** METHOD=0 below the first offset where the two agree within
0.5 dB, METHOD=1 from there on; all METHOD=0 when they never agree. The
manual describes METHOD=2 as a broadband combination without the
crossover rule, so the 0.5 dB rule is ESPice's (unconfirmed).

**CARRIERINDEX=k** reports the phase noise of harmonic k: METHOD=0 uses
k·f0 in the Lorentzian (the phase of harmonic k is k times the
fundamental's), METHOD=1 the sideband about k·f0.

**`.acphasenoise out in [interval] carrier=f`.** A phase-domain circuit
(node voltages stand for phases in radians, the usual PLL model) solved
by `.noise` over the `.ac` sweep. The output PSD S(f) in rad²/Hz is
published as `phnoise` = 10 log₁₀(S/2) dBc/Hz, the IEEE 1139
single-sideband L(f). The manual gives no formula; the factor 1/2 is
unconfirmed. CARRIER only scales HSPICE's jitter listing, which ESPice
does not publish.

**The PPV from the HB Jacobian.** The HB residual F(X, ω) of the
oscillator has J = ∂F/∂X singular along the time-shift direction X′. With
a synchronous perturbation B added to the residual, the perturbed solution
satisfies J δX + (∂F/∂ ln ω) δ(ln ω) = −B, and the left null vector y of J
turns that into δ(ln ω) = −yᵀB / (yᵀ ∂F/∂ ln ω). The autonomous Newton
Jacobian J_ω is J with the osc node's sin₁ column replaced by ∂F/∂ ln ω.
Solving J_ωᵀ y = e_ω gives (J ᵀy)_j = 0 for every j ≠ ω, and yᵀJX′ = 0 with
X′_ω ≠ 0 forces the last component to 0 as well. So y is the left null
vector, already normalized to yᵀ ∂F/∂ ln ω = 1, from one transposed solve
of the final Newton factor. That last Jacobian convolves C(t) as it does
G(t): Newton itself runs on the C(t₀) quasi-Newton charge blocks, which
drop a varactor's conversion of a slow control voltage into the carrier
and with it the PPV's DC part at the control node (the flicker
upconversion `varactor_flicker` checks). A constant perturbation drifts the phase at
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
2. `diffusion` (METHOD 0, 2): `hb.orbit` samples both the orbit and v₁
   on 64 points (a power of two covering 2(2K+1)); `collectNoiseSources`
   at every sample gives S_s(t_k); the white c is the sample mean of
   Σ_s (v_p − v_n)² S_s/2, and each source's flicker average
   ⟨(v_p − v_n) m_s⟩ is kept for c(f_m).
3. `periodic` (METHOD 1, 2): `pnoise.orbitSweep` about the HB orbit at
   k·f0 + f_m, divided by A_k²/2.
4. `stitch` (METHOD 2), then rows (frequency offset, `phnoise` in dBc/Hz).

`.acphasenoise` is `ac/noise.zig` with `phase` set.

Card: `.phasenoise v(out) sweep [f0 [K]] [METHOD=0|1|2] [CARRIERINDEX=k]
[LISTFREQ= LISTCOUNT= LISTFLOOR= LISTSOURCES=] [SPURIOUS=0]`. The LIST
keywords shape HSPICE's listing and are accepted and unused; SPURIOUS
other than 0 is refused. Without f0 the oscillator is the
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

`phasenoise/varactor_flicker`: the same tank tuned by a varactor charge
source C0(1 + k V(ctl)) at a JFET-loaded control node (drain flicker
KF·ID/f). The PPV at ctl is −(Rc k C0/C) cos²(ω₀t), whose mean
−Rc k C0/(2C) upconverts the flicker; c(f_m) and 𝓛 in closed form are in
the deck. METHOD=0 and METHOD=1 both match within 0.1 dB from 10 Hz to
10 kHz (the amplitude part is under 0.001 dB there).

`phasenoise/am_noise`: a weakly nonlinear Van der Pol tank (ε = 0.01)
whose amplitude relaxes at γ = 6e4 /s. The narrowband envelope gives
𝓛(f_m) = kT/(R C² A²)·[1/ω² + 1/(γ² + ω²)], phase plus amplitude noise;
METHOD=1 and METHOD=2 match within 0.1 dB at 1, 3.16 and 10 kHz. At
this ε the tank grows from the start's 1 mV kick by only e^0.94 in the 30
fixed settle periods, so the start keeps settling until the swing moves
under 1 % a period (`pss.zig` `startOscillator`, capped at 2000 periods);
without that the HB seed sits far from the limit cycle and HB does not
converge.

`phasenoise/acphasenoise_rc`: 4kTR of a 1 kΩ resistor through a 1 nF
pole as rad²/Hz, 𝓛 = 10 log₁₀(4kTR/(2(1 + (f/fc)²))), exact to 1e-6 dB.

## 4. Divergences and ceilings

- Flicker sources enter through c(f_m) in the white-noise Lorentzian, not
  Demir's full colored-noise spectrum (which is not one Lorentzian);
  close to the carrier, where c(f_m) f0² π approaches f_m, the two differ.
- The METHOD=2 crossover rule (first agreement within 0.5 dB) and the
  `.acphasenoise` factor 1/2 follow no documented HSPICE formula
  (unconfirmed).
- No LISTFREQ/LISTSOURCES listing, no jitter outputs, no SPURIOUS
  analysis.
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
