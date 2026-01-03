# Periodic Transfer Function (PXF) — future, not implemented

Adjoint of PAC: all inputs → one output, per frequency.

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
factorization serves both by solving with the transpose).

## 2. Flow

1. Same front end as PAC: periodic orbit, $\hat G_m$, $\hat C_m$.
2. Per output frequency: assemble $\mathcal A$ (or reuse PAC's), solve the
   conjugate-transposed system with the output selector, read all
   input/sideband entries.
3. Report per-input transfer tables; combine with source PSDs for
   noise-like rollups (this is also the correct adjoint front end for a
   true-LPTV pnoise upgrade — see [periodic-noise.md](periodic-noise.md)
   §1 "adjoint LPTV").

## Solvers used (requirements — analysis not implemented)

| Phase | Solver doc | Impl |
|---|---|---|
| Adjoint conversion-matrix solve $\mathcal A^{\mathsf H} Y = e$ (direct block or matrix-free with conjugated twiddles) | [lptv-block-solves.md](../solvers/lptv-block-solves.md) §"Transpose/adjoint solves" | requirement; dense seed = transpose flag on `pac.zig`'s solve; sparse blocks via `direct.zig solveT` (exists) |
| Time-domain alternative: transposed sensitivity replay over saved per-step factors | [monodromy-krylov.md](../solvers/monodromy-krylov.md) §"Adjoint recurrence" | requirement — shares the shooting tape |
| Preconditioning of the matrix-free adjoint (same block solves, `solveT` per sideband) | [structured-preconditioners.md](../solvers/structured-preconditioners.md) | requirement |
| GPU: frequency lanes + adjoint apply kernel | [lptv-block-solves.md](../solvers/lptv-block-solves.md) §4 | requirement |

---

**Sources fetched**: Kundert rf-sim.pdf (fetched — PXF definition and
adjoint duality verified). Adjoint conversion-matrix algebra: derived, not
source-verified. **Status: future — not implemented** (no `pxf.zig`;
lands as a transpose-solve flag on `pac.zig`'s sweep).
