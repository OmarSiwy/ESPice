# DC Transfer Function (.TF)

Small-signal gain, input resistance, output resistance in two linear
solves.

## 1. Mathematical specification

Linearize at the operating point: $G = \partial F/\partial x|_{x_0}$ (the
analytic conductance plane, ground row included). The three .TF quantities
are entries of $G^{-1}$ and $G^{-\mathsf T}$:

**Gain and input resistance — one forward solve.** A unit perturbation of
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

**Output resistance — one adjoint solve.** $R_{\text{out}}$ is the response
at the output to a unit current *injected at the output* with the input
source dead. By interreciprocity this is a transposed solve:

$$
G^{\mathsf T} y = e_{\text{out}}
\quad\Rightarrow\quad
R_{\text{out}} = y[\text{out}],
$$

(equivalently $R_{\text{out}} = e_{\text{out}}^{\mathsf T} G^{-1} e_{\text{out}}$
— symmetric in this diagonal case; the transpose form is used because it
generalizes to any output/source pair at one solve each). The input source
is "dead" automatically: its branch row clamps $\delta V_{\text{in}} = 0$
when the RHS entry is zero.

Error criteria: direct linear solves — accuracy inherited from the OP and
the factorization; no iteration.

## 2. Flow explanation

`src/analysis/dc/tf.zig`: one `eval()` at $x_{op}$ fills the
analytic $G$ plane; the analysis is then two dense LU solves ($n$ here is
small enough that dense beats sparse — one bulk arena, no per-solve
allocation). Forward solve with $e_{br}$ on the input source's branch row →
gain + $R_{\text{in}}$ ($R_{\text{in}} = \infty$ when the branch current
perturbation is exactly zero). Explicit transpose of $G$, second
factorization, solve with $e_{\text{out}}$ → $R_{\text{out}}$. Defaults:
input = first source's branch, output = last probe node.

Failure handling: a singular $G$ (floating output at DC) errors out of the
analysis; no partial results.

## 3. Pseudo-code, CPU sequential

```
tf(ckt, x_op, in_branch, out_node):
    eval(x_op)                      # analytic G plane
    J = denseG()
    v = lu_solve(J, e[in_branch])   # forward
    gain = v[out_node]
    Rin  = v[in_branch] != 0 ? -1/v[in_branch] : inf
    y = lu_solve(J^T, e[out_node])  # adjoint
    Rout = y[out_node]
```

## 4. Pseudo-code, GPU parallel

Not worth a kernel alone (two solves at op-point size). The parallel axis
is **batching across ensemble lanes**: in Monte-Carlo/corner runs each lane
has its own linearization — batch the $2L$ dense solves as one blocked
GETRF/GETRS (or reuse each lane's already-factored sparse Newton matrix:
forward = `solve`, adjoint = `solveT` on the same factors, zero extra
factorizations).

```
kernel tf_batched(lanes):
    per lane: forward solve + transposed solve on the lane's LU
    parallel over lanes; two dots per lane extract gain/Rin/Rout
```

## Solvers used

| Phase | Solver doc | Impl |
|---|---|---|
| Dense LU forward + transpose solve | none (dense path is below the sparse pipeline's scope) | `src/solvers/dense_lu.zig` `factorizeSolve` |
| The sparse alternative (reuse Newton factors: solve/solveT) | [klu-pipeline.md](../solvers/klu-pipeline.md) | `src/solvers/direct.zig` — upgrade path when n grows |
| Upstream OP | [homotopy-continuation.md](../solvers/homotopy-continuation.md), [newton-raphson-convergence.md](../solvers/newton-raphson-convergence.md) | `dc/op.zig`, `helper/converger.zig` |

---

**Sources fetched**

| Source | Status |
|---|---|
| ngspice manual §11.3.9 (.TF) | fetched — semantics confirmed (gain + input/output resistance at DC) |
| Adjoint/interreciprocity derivation | derived (standard; same identity as [ac-small-signal-noise.md](ac-small-signal-noise.md)) |

**Per-section verification**

- §1 branch-row excitation, $R_{\text{in}} = -1/i_{br}$ sign, transpose
  solve: verified against `tf.zig` source. §3: direct transcription.
- §4: prospective (not implemented on GPU).

**Our implementation**

- `src/analysis/dc/tf.zig`.
- Bench fixtures: `benchmark/fixtures/tf/*`.
