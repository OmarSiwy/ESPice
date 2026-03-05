# Periodic Transfer Function (PXF)

Adjoint of PAC: all inputs → one output, per frequency.

Implemented in `src/analysis/pss/pxf.zig`: periodic linearization shared
with PAC, followed by a dense adjoint conversion-matrix solve at each
frequency. Sparse, matrix-free, time-domain adjoint, and GPU batch paths
remain extensions.

## 1. Mathematical specification

PAC answers "input at $(x_{\text{in}}, f_{in})$ → response at all nodes
and sidebands." PXF answers the reverse: "response at one output
$(x_{\text{out}}, f_{\text{out}})$ ← every input node and every sideband."
Kundert rf-sim.pdf: "it is also possible to do the reverse, compute the
transfer functions from any input to a single output in one step using an
'adjoint' analysis... PXF is best at predicting the input images for a
particular output."

With the PAC conversion matrix $\mathcal A(f)$
([pac.md](pac.md) §1), the PXF quantities are rows of $\mathcal A^{-1}$
instead of columns: solve the **adjoint system**

$$
\mathcal A(f)^{\mathsf H}\, Y = e_{(\text{out},\, m=0)},
$$

then the transfer from *any* input node $i$ at sideband $m$ to the output
is $\overline{Y}_{(i,m)}$ (one dense vector read per input — no additional
solves). Uses: supply/LO feedthrough images, conversion gain from every
port at once, spur tables. Cost: identical to PAC per frequency point (one
factorization could serve both by solving with the transpose). The current
PAC and PXF queries build and factor their own matrices.

## 2. Flow

1. Same front end as PAC: periodic orbit, $\hat G_m$, $\hat C_m$.
2. Per output frequency: assemble $\mathcal A$ (or reuse PAC's), solve the
   conjugate-transposed system with the output selector, read all
   input/sideband entries.
3. Report per-input transfer tables. A future extension could combine them
   with source PSDs for noise-like rollups (the adjoint front end for a
   true-LPTV pnoise upgrade — see [periodic-noise.md](periodic-noise.md)
   §1 "adjoint LPTV").

## Solvers used and extensions

| Phase | Solver doc | Impl |
|---|---|---|
| Adjoint conversion-matrix solve $\mathcal A^{\mathsf H} Y = e$ | [lptv-block-solves.md](../solvers/lptv-block-solves.md) §"Transpose/adjoint solves" | `src/analysis/pss/pxf.zig`, `pac.buildConversionMatrix(true, ...)`, and `src/analysis/solvers/dense_lu.zig` |
| Time-domain alternative: transposed sensitivity replay over saved per-step factors | [monodromy-krylov.md](../solvers/monodromy-krylov.md) §"Adjoint recurrence" | requirement — shares the shooting tape |
| Preconditioning of the matrix-free adjoint (same block solves, `solveT` per sideband) | [structured-preconditioners.md](../solvers/structured-preconditioners.md) | requirement |
| GPU: frequency lanes + adjoint apply kernel | [lptv-block-solves.md](../solvers/lptv-block-solves.md) §4 | requirement |

---

**Sources fetched**: Kundert rf-sim.pdf (fetched — PXF definition and
adjoint duality verified). Adjoint conversion-matrix algebra: derived, not
source-verified. **Implementation status:** dense adjoint PXF is present;
the alternative solver paths in the table remain targets.
