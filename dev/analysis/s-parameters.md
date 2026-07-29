# S-Parameter Analysis

Port formulation, reference impedances, wave-variable extraction.

## 1. Mathematical specification

### Ports and wave variables

Each port $k$ is a netlist vsource (node $n_k$, MNA branch $b_k$) with
reference impedance $z_{0k}$ (default 50 Ω). Incident/reflected **power
waves** at port $k$ with port voltage $V_k$ and current into the DUT
$I_k$:

$$
a_k = \frac{V_k + z_{0k} I_k}{2\sqrt{z_{0k}}}, \qquad
b_k = \frac{V_k - z_{0k} I_k}{2\sqrt{z_{0k}}},
$$

(real $z_0$; the general complex-$z_0$ pseudo-wave definition reduces to
this). The S-matrix is defined by $b = S\,a$ with all other ports
**terminated in their reference impedance** ($a_j = 0,\ j \ne k$):

$$
S_{jk}(\omega) = \frac{b_j}{a_k}\Big|_{a_{l\ne k} = 0}.
$$

### MNA realization of terminated ports

A z0-termination is folded into the port source itself: modify the branch
equation from $v_p - v_n = V_s$ to the **Thevenin form**

$$
v_p - v_n - z_0\, i_{br} = V_s
\quad\Longleftrightarrow\quad
G[b_k, b_k] \mathrel{-}= z_0,
$$

so an *unexcited* port ($V_s = 0$) presents exactly $z_0$ to the DUT
instead of clamping its node, and an excited port is a source with $z_0$
in series. Driving port $k$ with unit source voltage gives incident wave
$a_k = \frac{1}{2\sqrt{z_{0k}}}$ (the source splits between $z_0$ and the
matched-condition definition), and every port's reflected wave is read
from the same solve:

$$
b_j = \frac{V_j - z_{0j} I_j}{2\sqrt{z_{0j}}},
\qquad I_j = -\,i_{br_j}
$$

(branch stamps $F_p = +i_{br}$, so current into the DUT is the negated
branch unknown). One frequency point costs one factorization of
$G' + j\omega C$ ($G'$ = terminated conductance matrix) and $P$ solves
(one per driven port) to fill the whole $P \times P$ S-matrix column by
column.

Derived quantities follow standard conversions ($Z = \sqrt{z_0}(I-S)^{-1}(I+S)\sqrt{z_0}$
etc.); the analysis outputs $S$ directly.

## 2. Flow explanation

`src/analysis/ac/sp.zig`:

1. `FreqSolver.fromCircuit`: one `eval()` at $x_{op}$ and the solver's own
   copies of the $G$/$C$ planes (dense for $n \le 16$, the sparse
   stacked-real CSC above). The port termination is an *analysis-side*
   modification, so `addDiagG` stamps it on the copy ($-z_0$ on each
   port's branch diagonal, a slot every pattern has), never on the circuit
   planes.
2. One unit RHS per port $p$ on branch $b_p$, stacked into one
   `n_ports`·$2n$ right-hand side.
3. Sweep (log or linear, `n_points`) through `freq.Stream`, as ac does:
   each frequency is one `LaneLu` lane, factored once and solved for every
   port. Column $p$ of $S(\omega)$ is $b_k/a_p$ from port $p$'s solution.

Defaults: with no explicit port list, the drive source becomes port 1 (a
1-port $S_{11}$ measurement). Failure: singular factorization at a
frequency point errors the sweep.

Knobs: the shared `sweep` grid (`f_start`/`f_stop`/`points`/`kind`), per-port `z0`.

## 3. Pseudo-code, CPU sequential

```
sp_sweep(ckt, x_op, ports):
    fs = FreqSolver(eval(x_op))                  # stacked-real 2n, own G, C copies
    for k in ports: fs.G[b_k, b_k] -= z0_k       # Thevenin termination
    for f in sweep:
        fs.set_omega(2*pi*f)
        for p in ports:                          # one solve per driven port
            x = fs.solve(e[b_p])                 # unit source voltage
            a_p = 1/(2*sqrt(z0_p))
            for k in ports:
                V_k = x[n_k] (+j x[n+n_k]);  I_k = -(x[b_k] + j x[n+b_k])
                b_k = (V_k - z0_k*I_k)/(2*sqrt(z0_k))
                S[k][p](f) = b_k / a_p
```

## 4. Parallel design notes

Same shape as AC ([ac-small-signal-noise.md](ac-small-signal-noise.md) §4)
with one extra inner axis:

- **frequency points**: independent lanes (shared symbolic, per-lane
  values), implemented as `LaneLu` lanes through `freq.Stream`;
- **driven ports**: the $P$ RHS per frequency share one factorization
  (implemented as $P$ lane solves per lane refactor; a blocked
  triangular solve is not);
- wave extraction is a trivial per-lane epilogue.

```
kernel sp(lanes = freq points):
    build values for omega_lane; factor (batched) or GMRES matrix-free
    block-solve P RHS (unit branch excitations)
    parallel over (k, p): S[k][p] = wave_ratio(x_p, port k)
```

## 5. HSPICE `.lin`

`.lin [noisecalc=0|1|2] [gdcalc=0|1] [mixedmode2port=xy] [format=touchstone]
[filename=f]` runs as an `.sp` query (`Sp.lin`) over the first `.ac` card's
sweep, with ports from P elements (`P1 in 0 port=1 z0=50`, read as a V card
whose `port=` is ngspice's `portnum`; the port voltage is v(n+) - v(n-)).
The plot is `LIN Analysis`:

| Columns | Meaning |
|---|---|
| `S(i,j)`, `Y(i,j)`, `Z(i,j)` | full N-port matrices; with $F = \mathrm{diag}(\sqrt{z_0})$, $Y = F^{-1}(E+S)^{-1}(E-S)F^{-1}$, $Z = F(E-S)^{-1}(E+S)F$ on a small dense complex solve |
| `H(i,j)` | two-port hybrid parameters of ports 1-2, from the Z of the 2x2 S block (other ports terminated in z0, as HSPICE defines it) |
| `TD(X(i,j))` | `gdcalc=1`: group delay $-\mathrm{Im}(X'/X)$ of every S, Y, Z and H entry, s |
| `K_STABILITY_FACTOR`, `MU_STABILITY_FACTOR` | two or more ports: Rollett's $K = (1 - \lvert S_{11}\rvert^2 - \lvert S_{22}\rvert^2 + \lvert\Delta\rvert^2)/2\lvert S_{12}S_{21}\rvert$ and Edwards-Sinsky's $\mu = (1 - \lvert S_{11}\rvert^2)/(\lvert S_{22} - \Delta S_{11}^*\rvert + \lvert S_{12}S_{21}\rvert)$ of the two-port block, $\Delta = S_{11}S_{22} - S_{12}S_{21}$; a unilateral block gives an infinite K |
| `NFMIN`, `NF`, `RN`, `YOPT`, `GAMMA_OPT` | `noisecalc=1`: two-port noise parameters between ports 1 and 2 (power ratios, ohm, S, reflection against port 1's z0) |

**Group delay** is a central difference at $\omega(1 \pm 10^{-5})$: two more
frequency lanes per point, solved against the same port drives. The plan
proposed the exact derivative $dx/d\omega = -A^{-1}(jC)x$; the difference
was chosen because it also differentiates frequency-dependent stamps
(`acDyn`: transmission lines), which $jC$ misses, and costs no new solver
path. Truncation and roundoff are both near $10^{-10}$ relative; the
fixtures agree with the exact derivative to better than $10^{-6}$
relative, a matched line's `TD(S(2,1))` with its 1 ns delay included.

**Noise parameters.** One adjoint sweep with a right-hand side per port
(ports 1 and 2) gives each device generator's transfer to the terminated
port voltages. The stacked-real transpose solve is $A^H y = e$, so the
transfer is $\overline{y_p - y_n}$. With every port terminated in its
noiseless z0 the incident waves vanish and the noise waves are
$c_k = v_k/\sqrt{z_{0k}}$, so $C_S = \sum_s \mathrm{PSD}_s\, h_s h_s^H$ scaled
by $1/\sqrt{z_{0i} z_{0j}}$. The short-circuit noise currents are
$i = -2F^{-1}(E+S)^{-1}c$ (Hillbrand and Russer 1976), and the chain form
puts $v_n = -i_2/Y_{21}$, $i_n = i_1 - (Y_{11}/Y_{21}) i_2$ at the input.
With $S_{vv}$, $S_{ii}$, $S_{iv} = \langle i_n v_n^* \rangle$ and
$4kT_0$ at $T_0 = 290$ K (k is ngspice's CONSTboltz, the devices'):
$R_n = S_{vv}/4kT_0$,
$Y_{opt} = (\sqrt{S_{ii}S_{vv} - \mathrm{Im}^2 S_{iv}} - j\,\mathrm{Im}\,S_{iv})/S_{vv}$,
$F_{min} = 1 + (\mathrm{Re}\,S_{iv} + \sqrt{S_{ii}S_{vv} - \mathrm{Im}^2 S_{iv}})/2kT_0$,
and NF at $Y_s = 1/z_{01}$.

**P elements.** A P card keeps its z0 in series in every analysis, as
HSPICE does [SA Ch.17]: the builder puts a noiseless resistor (the
resistor model with `noisy=0`) between n+ and a hidden node the source
drives, so DC, transient and HB see a source behind z0. The port node is
still n+, and `Port.series_z0` tells `sp.zig` and `hb_lptv.zig` not to
add the $-z_0$ branch term on top. ngspice's `portnum` V card stays an
ideal source terminated only inside the port analyses.

**Mixed mode.** `P1 inp inn ref port=1 z0=50` (three nodes; a third word
that is neither a key nor a source keyword is the reference node) is a
balanced port. The card's value V drives a hidden node against ref, and
each leg is a VCVS of gain ±1/2 on it behind its own z0, so each leg is a
single-ended port against ref. `sp.zig` solves over the legs and then
changes basis: differential mode $(a_+ - a_-)/\sqrt2$ against $2z_0$,
common mode $(a_+ + a_-)/\sqrt2$ against $z_0/2$ (Bockelman and
Eisenstadt 1995). That map M is orthogonal, so $S_{mm} = M S M^T$, and Y,
Z, H, K, μ and the noise parameters follow from $S_{mm}$ with the mode
impedances. Modes are numbered as HSPICE writes them to Touchstone: every
port's first mode (single-ended or differential) in port order, then the
common modes of the balanced ports, so two balanced ports give
S(1,3) = SDC11. `mixedmode2port=xy` picks port 1's and port 2's mode for
the two-port measurements (`s` for a single-ended port, `d` or `c` for a
balanced one; a mismatch is `InvalidAnalysisArguments`).

**`.net`** (HSPICE's obsolete form, [CR App.A]): `.net input [RIN=r]`,
`.net input r` or `.net output input [ROUT=r] [RIN=r]`, where the input
is a V or I card and the output is `v(n1[,n2])` or `i(Vx)`. Each port is
driven as what it is, ideal: a V card's port is a voltage (a short when
undriven), an I card's or a node pair's a current (an open). Per
frequency the two drives give the port voltages and currents, Z follows
from $Z = V_m I_m^{-1}$, and S is taken against RIN and ROUT (default
1 ohm). The plot is the `.lin` one without group delay or noise.

**Touchstone.** `format=touchstone` (or `touchstone2`) writes
`<filename or deck name>.s<N>p` beside the deck after the plot is
published: the S block in RI, then for two ports the noise block
`f NFmin(dB) |Γopt| ∠Γopt RN/z0`. When every mode has one reference
impedance the file is Touchstone 1.0 with that z0 in its option line;
otherwise (a balanced port, or 50 and 75 ohm ports) it is Touchstone 2.0
with a `[Reference]` line listing each port's, which 1.0 cannot express.
`--format=touchstone` writes the same file for an `.sp`/`.lin` query, but
a `.lin` deck also publishes its `.ac` plot, which that format refuses;
the side file is the route for decks.

**Oracles** (`tests/fixtures/hspice/lin_*`): analytic. `lin_pad` is the
matched pi pad (S, Y, Z, H closed forms; a matched pad at 290 K has
NF = NFMIN = its loss, 4). `lin_rc_noise` is a lossy RC two-port with 50
and 75 ohm ports: nodal Y with the inner node eliminated, S, Z, H from it,
group delay from the exact $dY/d\omega$, and the noise parameters by
Twiss's theorem ($C_Y = 4kT\,\mathrm{Re}\,Y$ for a passive network at one
temperature) read through the textbook Rn, Gu, Yc route. Its NF matches
ngspice `.noise` on the same network with a 50 ohm source and a noiseless
75 ohm load (4.70010 at 1 MHz, ngspice's printed digits). `lin_line` is a
matched lossless line: $S_{21} = e^{-j\omega t_d}$, group delay $t_d$. `lin_mixed_mode`
is a balanced port 1 and a single-ended port 2 on an asymmetric RC
network: the nodal Z of the three port nodes mapped to the modes by
$V_d = V_a - V_b$, $I_d = (I_a - I_b)/2$, $V_c = (V_a + V_b)/2$,
$I_c = I_a + I_b$, then S, Y, H, K and μ by the closed forms.
`net_tpad_y` and `net_tpad_z` are the same resistive T driven by V and by
I cards (same answer), `net_one_port` a series RC. `port_series_z0` checks
z0 in the OP and transient (a divider and an RC charge).

**Divergences from HSPICE**, each a `ponytail:` until a deck needs it:

- `noisecalc=2` publishes the two-port parameters only; the gain and
  matching measurements (G_MAX, ...) are not built; `dataformat` is
  always RI.
- `.net` ports are ideal (no z0 inside the circuit), and RIN/ROUT only
  normalize S. This follows the manual and is unconfirmed against HSPICE.
- The mixed-mode mode order and the three-node P card reading follow the
  manual and are unconfirmed against HSPICE.

## Solvers used

| Phase | Solver doc | Impl |
|---|---|---|
| Stacked-real frequency solves | [klu-pipeline.md](../solvers/klu-pipeline.md) (sparse path), dense below threshold | `src/solver/freq_solve.zig` (`fromCircuit`, `addDiagG`, `solveBatch`; `DENSE_THRESHOLD = 16`) |
| Dense factorization per point | none (dense path) | `src/solver/dense_lu.zig` |
| Upstream OP | [homotopy-continuation.md](../solvers/homotopy-continuation.md) | `dc/op.zig` |

Note: sp used to run every deck through a dense $2n$ LU per frequency and
one solve per port, whatever $n$. A 300-stage two-port RC ladder (302
nodes, `.sp dec 50 1k 1g`, 301 points) took 25.26G Ir and 2.6 s that way;
the sparse lane path takes 37.9M Ir and 0.01 s, and the S-matrix moves by
roundoff only (5.2e-14 absolute). Every corpus sp deck has $n \le 16$,
stays dense, and is byte-identical.

---

**Sources fetched**

| Source | Status |
|---|---|
| Kundert rf-sim.pdf | fetched (background; no S-param formulation section) |
| Power-wave definition (Kurokawa 1965) | **paywalled: derived, not source-verified** (standard definition) |
| designers-guide S-param paper | none found on the fetched analysis index |

**Per-section verification**

- §1 Thevenin termination stamp, $a$/$b$ extraction incl. the
  $I = -i_{br}$ sign and $a_p = 1/(2\sqrt{z_0})$: verified against
  `sp.zig` source.
- §2/§3: direct transcription. §4: design notes.

**Our implementation**

- `src/analysis/ac/sp.zig`.
- Fixtures: `tests/fixtures/sp/`.
