# DC Transfer Function (.TF)

Small-signal gain, input resistance, output resistance in two linear
solves.

## 1. Mathematical specification

Linearize at the operating point: $G = \partial F/\partial x|_{x_0}$ (the
analytic conductance plane, ground row included). The three .TF quantities
are entries of $G^{-1}$ and $G^{-\mathsf T}$:

**Gain and input resistance: one forward solve.** A unit perturbation of
the input source voltage enters on its **branch row** (branch equation
$v_p - v_n - V = 0$, so $\delta V = 1 \Rightarrow \text{rhs} = e_{br}$):

$$
G\,v = e_{br}
\quad\Rightarrow\quad
A_v = \frac{\partial v_{\text{out}}}{\partial V_{\text{in}}} = v[\text{out}],
$$

and the input resistance follows from the same solve's branch-current
entry. With the branch stamping $F_p = +i_{br}$, current delivered into
the circuit is $-i_{br}$:

$$
R_{\text{in}} = \frac{\partial V_{\text{in}}}{\partial I_{\text{delivered}}}
= \frac{-1}{v[br]} .
$$

**Output resistance: one adjoint solve.** $R_{\text{out}}$ is the response
at the output to a unit current *injected at the output* with the input
source dead. By interreciprocity this is a transposed solve:

$$
G^{\mathsf T} y = e_{\text{out}}
\quad\Rightarrow\quad
R_{\text{out}} = y[\text{out}],
$$

(equivalently $R_{\text{out}} = e_{\text{out}}^{\mathsf T} G^{-1} e_{\text{out}}$
- symmetric in this diagonal case; the transpose form is used because it
generalizes to any output/source pair at one solve each). The input source
is "dead" automatically: its branch row clamps $\delta V_{\text{in}} = 0$
when the RHS entry is zero.

A current output `i(Vx)` puts $e_{\text{out}}$ on Vx's branch row: a unit
volt on the sensing source. $y[br] = (G^{-1})_{br,br}$ is the branch current
that volt moves, and as for $R_{\text{in}}$ the resistance Vx sees is
$R_{\text{out}} = -1/y[br]$ (`1e20` when $|y[br]| < 10^{-20}$, the value
ngspice prints there).

Infinite resistances print as `1e20`, ngspice's value (#193): `tfanal.c`
writes `1e20` for $R_{\text{in}}$ when $|i_{br}| < 10^{-20}$, and its
current-output clamp gives `1e20` when $y[br] < 10^{-20}$. Measured with ngspice-45
on the divider plus an open `V2 c 0 1`: `tf i(V2) V2` prints 0, 1e20, 1e20,
and `tf v(out) V2` 0, 1e20, 750; the `tf` tests in
`src/analysis/tests/sweep.zig` pin both. `tf.impedance` applies the same
$|i| < 10^{-20}$ floor (#199), so a current in $(0, 10^{-20})$ also reads
`1e20` (`tf/tiny_input_conductance`: a 1e-30 S path, Rin 1e20, not 1e30).
The floor is `.tf`'s alone: `.dcxf` and `.acxf` are VACASK's analyses and
keep its exact-zero rule (§5).

Divergence: ngspice's `tfanal.c` reports $1/\max(10^{-20}, y[br])$ for a
current output. A passive circuit always gives $y[br] < 0$ under that sign,
so ngspice prints `1e20` where the resistance is finite (#149): R1 1k and R2
1k in series to the sensing source read 2k here, 1e20 there. A deck that
relied on ngspice's value has nothing to change but its expectation; the
fixture `tf/current_output` pins the 1k case.

Error criteria: direct linear solves: accuracy inherited from the OP and
the factorization; no iteration.

## 2. Flow explanation

`src/analysis/dc/tf.zig` is `.dcxf`'s readout (§5) for one source: one
`eval()` at $x_{op}$ fills the analytic $G$ plane, the circuit workspace's
sparse solver factors it once, and both solves reuse that factorization.
Forward solve with the input's unit excitation (`xf.excite`: $e_{br}$ on a V
card's branch row, a unit current through an I card) → gain (`Output.read`)
+ $R_{\text{in}}$ (`tf.impedance` over `xf.immittance`, $10^{20}$ when the
branch current perturbation is below $10^{-20}$). Adjoint `solveT` with $e_{\text{out}}$
(`Output.seed`) → $R_{\text{out}}$. Defaults: input = first source's
branch, output = last probe node. Until #193 `.tf` built a dense copy of $G$
and factored it with `dense_lu`, O(n²) memory and O(n³) time; the sparse
path rounds differently in the last bits.

Failure handling: a singular $G$ (floating output at DC) errors out of the
analysis; no partial results.

## 3. Pseudo-code, CPU sequential

```
tf(ckt, x_op, in_branch, out_node):
    eval(x_op)                      # analytic G plane
    lu = sparse_factor(G)
    v = lu.solve(e[in_branch])      # forward
    gain = v[out_node]
    Rin  = |v[in_branch]| >= 1e-20 ? -1/v[in_branch] : 1e20
    y = lu.solveT(e[out_node])      # adjoint, same factors
    Rout = y[out_node]
```

## 4. Parallel design notes (not implemented)

Not worth a kernel alone (two solves at op-point size). The parallel axis
is **batching across ensemble lanes**: in Monte-Carlo/corner runs each lane
has its own linearization, and each lane's sparse factorization serves its
forward `solve` and adjoint `solveT`, as the scalar path does.

```
kernel tf_batched(lanes):
    per lane: forward solve + transposed solve on the lane's LU
    parallel over lanes; two dots per lane extract gain/Rin/Rout
```

## 5. All-source transfer: `.dcxf`, `.acxf`, `.dcinc`

VACASK's `dcxf`, `acxf` and `dcinc` (`lib/coredcxf.cpp`,
`coreacxf.cpp`, `coredcinc.cpp`, read from its source), in SPICE card
form:

```
.dcxf v(out)|v(a,b)|i(Vx) [tf]
.acxf v(out)|v(a,b)|i(Vx) dec|oct|lin N f1 f2 [tf]
.dcinc
```

`.dcxf` publishes one real row and `.acxf` a complex sweep with
`tf(src)`, `zin(src)` and `yin(src)` for every independent source, V
cards then I cards in card order. A V card's excitation is 1 V on its
branch row; an I card's is 1 A through the card, the stamps its AC
magnitude makes. `zin` is the impedance the source sees with every
other source in place: $-1/i_{br}$ per volt for a V card, the terminal
voltage per ampere for an I card; `yin = 1/zin`.

- Without `tf`, each source is one forward right-hand side (VACASK's
  method): `.dcxf` reuses one sparse factorization of G, `.acxf` puts
  every source on the same lane factorization per frequency
  (`FreqSolver.solveBatch`). One solve per source gives all three values.
- With `tf`, one adjoint solve $A^T y = e_{out}$ gives every transfer at
  once: $tf = y_{br}$ for a V card, $y_{n} - y_{p}$ for an I card. One
  solve instead of one per source; `zin`/`yin` need the per-source solves,
  so the flag drops them.

`.dcinc` solves $G\,\Delta x = \Delta u$ at the operating point, $\Delta u$
the deck's AC excitation, and publishes the deck's probes (`v(node)`,
`i(Vx)`) as one real row.

Divergences, recorded:

- An infinite `zin` or `yin` is VACASK's finite `1e20`, so the row stays
  finite. As in VACASK, only an exact zero clamps: `coredcxf.cpp:268-273`
  (`yin != 0.0 ? 1.0/yin : 1e20` for a V card), `:277-282` (the same on
  `zin` for an I card), and `coreacxf.cpp:484-488` / `:493-497` on the
  complex values (VACASK unstable-2026, the benchmarking shell's
  `vacask-unstable-2026` source). A tiny nonzero value inverts to a huge
  one, as it does there. ESPice inverts by Smith's division
  (`xf.reciprocal`), which never squares $|v|$, so a value below
  $10^{-154}$ inverts instead of reading `inf` (#199); a real value gives
  exactly `1/v`, VACASK's DC `1.0/yin`. `.tf` alone adds ngspice's
  $10^{-20}$ floor (§1).
- VACASK saves only `tf` and `zin` by default and `yin` on request; we
  always publish all three.
- `.dcinc` takes the real part of each source's AC excitation, so a
  phase other than 0 or 180° scales it by cos(phase). VACASK reads `mag`
  alone and has no phase to apply.
- A V card sensed by an F, H or W element is a source of `.dcxf`/`.acxf`
  like any other (`xf/sensed_source`), as in VACASK.
- ponytail: the forward `.acxf` path holds 64·sources·2n values per lane
  chunk; split the sources into groups when a deck with hundreds of
  sources and a large n needs it.

Oracles: `tests/conformance/tests/netlist/xf/diode_divider` (VACASK unstable-2026 run of
the same circuit, every column of all three analyses, both paths) and
`xf/resistive_bridge` (analytic, `v(a,b)` and `i(V1)` outputs).

## Solvers used

| Phase | Solver doc | Impl |
|---|---|---|
| Sparse LU forward + transpose solve on one factorization | [klu-pipeline.md](../solvers/klu-pipeline.md) | `src/solver/direct.zig` `Solver.solve`/`solveT` |
| Upstream OP | [homotopy-continuation.md](../solvers/homotopy-continuation.md), [newton-raphson-convergence.md](../solvers/newton-raphson-convergence.md) | `dc/op.zig`, `src/solver/converger.zig` |

---

**Sources fetched**

| Source | Status |
|---|---|
| ngspice manual §11.3.9 (.TF) | fetched: semantics confirmed (gain + input/output resistance at DC) |
| Adjoint/interreciprocity derivation | derived (standard; same identity as [ac-small-signal-noise.md](ac-small-signal-noise.md)) |

**Per-section verification**

- §1 branch-row excitation, $R_{\text{in}} = -1/i_{br}$ sign, transpose
  solve: verified against `tf.zig` source. §3: direct transcription.
- §4: design notes.

**Our implementation**

- `src/analysis/dc/tf.zig`.
- Fixtures: `tests/conformance/tests/netlist/tf/`.
