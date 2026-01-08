# Gilbert–Peierls Left-Looking Sparse LU with Symbolic DFS Reachability

## 1. Mathematical specification

**Factorization.** Solve $Ax = b$ with $A \in \mathbb{R}^{n \times n}$ sparse and
nonsingular by computing $PA = LU$ where $L$ is unit lower triangular, $U$ upper
triangular, and $P$ a row permutation from partial pivoting. Then

$$Ly = Pb, \qquad Ux = y.$$

**Left-looking column formulation.** Partition (thesis eq. 2–9, at step $k$
with $A_{11}$ the leading $(k{-}1)\times(k{-}1)$ block already factored):

$$
\begin{bmatrix} A_{11} & \mathbf{a_{12}} & A_{13} \\
\mathbf{a_{21}} & a_{22} & \mathbf{a_{23}} \\
A_{31} & \mathbf{a_{32}} & A_{33} \end{bmatrix}
=
\begin{bmatrix} L_{11} & 0 & 0 \\ \mathbf{l_{21}} & 1 & 0 \\ L_{31} & \mathbf{l_{32}} & L_{33} \end{bmatrix}
\begin{bmatrix} U_{11} & \mathbf{u_{12}} & U_{13} \\ 0 & u_{22} & \mathbf{u_{23}} \\ 0 & 0 & U_{33} \end{bmatrix}.
$$

Equating column $k$ gives the three defining equations

$$L_{11}\,\mathbf{u_{12}} = \mathbf{a_{12}}, \qquad
u_{22} = a_{22} - \mathbf{l_{21}}\,\mathbf{u_{12}}, \qquad
\mathbf{l_{32}} = \frac{1}{u_{22}}\left(\mathbf{a_{32}} - L_{31}\,\mathbf{u_{12}}\right),$$

which collapse into ONE sparse lower-triangular solve (thesis eq. 2–21):

$$
\begin{bmatrix} L_{11} & 0 & 0 \\ \mathbf{l_{21}} & 1 & 0 \\ L_{31} & 0 & I \end{bmatrix}
\begin{bmatrix} \mathbf{u_{12}} \\ u_{22} \\ \mathbf{l_{32}}\,u_{22} \end{bmatrix}
=
\begin{bmatrix} \mathbf{a_{12}} \\ a_{22} \\ \mathbf{a_{32}} \end{bmatrix},
\quad\text{i.e.}\quad x = L^{-1} A(:,k),\; U(1{:}k,k)=x(1{:}k),\; L(k{:}n,k)=x(k{:}n)/x(k).
$$

Column $k$ of both factors is therefore obtained by solving $Lx = A(:,k)$
against the $k{-}1$ columns of $L$ already computed — hence *left-looking*.

**Symbolic reachability (the core theorem).** With partial pivoting the
pattern of $L,U$ is unknowable ahead of numeric work, so the pattern of each
$x$ must be computed *per column* in time proportional to its size. Let
$G(L_k)$ be the directed graph on the $k{-}1$ factored columns with edge
$j \to i$ iff $l_{ij} \ne 0$, and let $\beta = \{i : b_i \ne 0\}$ be the
pattern of $b = A(:,k)$. Then the nonzero pattern $X = \{i : x_i \ne 0\}$
of the triangular solve satisfies (Gilbert–Peierls; thesis eq. 2–22, no
numerical cancellation assumed):

$$X = \mathrm{Reach}_{G(L)}(\beta).$$

Justification: $b_j \ne 0 \Rightarrow x_j \ne 0$, and $x_j \ne 0 \wedge
l_{ij} \ne 0 \Rightarrow x_i \ne 0$ (the update $x_i \mathrel{-}= l_{ij} x_j$
introduces a nonzero). Closure of these two rules is exactly graph
reachability. A depth-first search from every vertex in $\beta$ computes $X$
in time proportional to the number of vertices visited plus edges traversed
— i.e. proportional to the numeric flops that follow.

**Topological elimination order.** The unknowns of $Lx=b$ need not be
eliminated in increasing row-index order (sorting would break the complexity
bound); any *topological order* of $X$ w.r.t. $G(L)$ works, because $x_i$
only needs all $x_j$ with $j \to i$ finalized first. DFS finish order,
reversed, is such a topological order for free — DFS finishes $i$ before
every $j$ from which $i$ was reached.

**Complexity.** Let $\eta(A) = \mathrm{nnz}(A)$ and $\mathrm{flops}(LU)$ the
number of multiply–adds in the product $L \cdot U$. Gilbert–Peierls factors in

$$O\!\left(\eta(A) + \mathrm{flops}(LU)\right),$$

i.e. total time proportional to arithmetic actually performed — the defining
property of the algorithm. A naive column solve costing $O(n)$ per column
would add an $O(n^2)$ term; the reachability computation removes it.

**Threshold partial pivoting bound.** At step $k$, among the pivot
candidates $x_i$, $i \ge k$ (unpivoted rows in $X$), pick the diagonal $d$
whenever

$$|d| \ge \tau \cdot \max_{i}|x_i|, \qquad \tau \in (0,1],$$

else pick the column max. Every multiplier then satisfies $|l_{ik}| \le
1/\tau$, bounding element growth per step by $1 + 1/\tau$; growth is
monitored, not eliminated (see `klu-pipeline.md`). $\tau = 1$ recovers
classical partial pivoting ($|l_{ik}| \le 1$, worst-case growth $2^{n-1}$).

## 2. Flow explanation

Three phases, run per column inside one left-to-right sweep:

- **Symbolic (reach):** DFS in $G(L)$ from the pattern of $A(:,c)$. Marks
  visited rows with a per-column epoch (no clearing between columns), pushes
  finished vertices onto a topological list. Data: an explicit vertex stack
  plus a parallel "position stack" holding each frame's resume offset into
  the adjacency (thesis §2.13 — iterative DFS avoids stack overflow on
  dense columns; our `pstack` is exactly this).
- **Numeric (sparse triangular solve):** scatter $A(:,c)$ into a dense
  workspace `w[n]`, then walk the topological list in reverse finish order;
  for each finished vertex with a pivot assignment, record $u_{ik}$ and
  saxpy $-u_{ik} \cdot L(:,i)$ into `w`. Only touched entries of `w` are
  ever read or cleared, keeping the flop bound.
- **Pivot + store:** scan the candidate rows (unpivoted entries of the
  reach set) for the column max, apply the threshold-diagonal rule, divide
  candidates by the pivot, append to $L$, clear `w` along the pattern.

Data structures: $A$ in compressed sparse column (CSC: `col_ptr`,
`row_idx`, `vals` — thesis §2.2); $L$ and $U$ as growing per-column CSC
arrays; `pinv` maps original row → pivot step (rows of $L$ are stored in
*permuted* coordinates once the sweep completes). Storing $U$'s per-column
rows **in the topological order used by the solve** is what makes numeric
refactorization a straight-line replay later (see `klu-pipeline.md`).

When it wins: circuit matrices are extremely sparse with little fill, so
flops(LU) ≈ nnz(L+U) ≈ small multiple of nnz(A); the non-supernodal,
BLAS-free formulation beats supernodal codes (SuperLU, UMFPACK) that
amortize their overhead on dense sub-blocks circuit matrices don't have
(thesis ch. 3: KLU 1.5–3× faster than SuperLU, ~1000× vs Sparse1.3 on
circuit matrices). For matrices with large dense fill, supernodal/multifrontal
methods win instead.

## 3. Pseudo-code, CPU sequential

Matches `modules/solvers/src/direct.zig` `Lu.factor` (SoA CSC, u32 indices,
`NONE = maxInt(u32)`, workspaces `w/flag/topo/stack/pstack` allocated once
at init):

```
factor(col_ptr, row_idx, vals, tau):
  pinv[0..n] = NONE                      # row -> pivot step, NONE = unpivoted
  for k in 0..n:                         # pivot steps, column c = q[k] of A
    c = q[k]                             # q from BTF+AMD (see amd-ordering.md)
    lp[k] = len(li); up[k] = len(ui)
    mark = k + 1

    # ---- symbolic: reach = DFS from pattern of A[:,c] through G(L) ----
    nt = 0
    for p in col_ptr[c] .. col_ptr[c+1]:
      r = row_idx[p]
      if flag[r] == mark: continue
      push r (stack[0]=r, pstack[0]=start of L-column pinv[r], flag[r]=mark)
      loop:
        r = stack[top]
        kc = pinv[r]                     # factored column reached through row r
        # resume scanning children li[pstack[top] .. lp[kc+1])
        if unvisited child found: mark it, push it, continue
        topo[nt++] = r                   # DFS finish: r is topologically last
        pop; if stack empty: break

    # ---- numeric: scatter + sparse lower-triangular solve ----
    for p in col_ptr[c] .. col_ptr[c+1]: w[row_idx[p]] = vals[p]
    for idx in reverse(0..nt):           # reverse finish order = topo order
      r = topo[idx]; kc = pinv[r]
      if kc == NONE: continue            # pivot candidate row, no L column yet
      ukr = w[r]
      append (kc, ukr) to (ui, ux)       # U rows stored IN SOLVE ORDER
      for p in lp[kc] .. lp[kc+1]:
        w[li[p]] -= lx[p] * ukr          # saxpy along L[:,kc]

    # ---- threshold partial pivoting, diagonal preferred ----
    amax = max |w[r]| over r in topo[0..nt] with pinv[r] == NONE; piv = argmax
    if amax == 0 or !finite(amax): error SingularMatrix
    if pinv[c] == NONE and |w[c]| >= tau * amax: piv = c
    udiag[k] = w[piv]; pinv[piv] = k

    # ---- store scaled L column, clear w along the pattern ----
    for r in topo[0..nt]:
      if pinv[r] == NONE: append (r, w[r]/udiag[k]) to (li, lx)
      w[r] = 0

  map li[*] through pinv                 # L rows -> permuted coordinates
  prow[p] = pinv[row_idx[p]]             # refactor scatter targets
```

Solve (`Lu.solve`): permute $b$ by `pinv`, forward-substitute through
`lp/li/lx` skipping zero $y_k$, back-substitute through `up/ui/ux` dividing
by `udiag`, un-permute by `q`. Transpose solve runs the same arrays in
gather mode ($U^T$ lower, $L^T$ unit upper).

## 4. Pseudo-code, GPU parallel

What fundamentally serializes: column $k$'s triangular solve consumes
finished columns $\{i : u_{ik} \ne 0\}$ — a data dependence chain whose
depth is the height of the column dependency DAG (the elimination-tree
height for symmetric patterns). No scheduling removes it; GPU factorization
therefore parallelizes *within* levels of that DAG, never across the chain
(GLU-style level sets — details and kernel modes in `gpu-sparse-lu.md`).

The symbolic DFS itself is inherently sequential per column (stack-ordered)
and is kept on the CPU / done once; the GPU replays numeric work on a frozen
pattern — which is exactly our refactor discipline.

```
# one-time on CPU: factor() as above, then levelize the column DAG:
#   dep(k) = { i : ui[up[k]..up[k+1]) }          (U pattern = who k reads)
#   level[k] = 1 + max(level[i] for i in dep(k)), level of a leaf = 0
#   levels[] = columns bucketed by level, ascending

gpu_refactor(col_ptr, prow, vals, lp/li/lx, up/ui/ux, udiag, levels):
  # SoA CSC on device, u32 indices, all buffers allocated once (our layout)
  scatter kernel: for each column k in parallel:
    w_k = per-column slice of a preallocated dense workspace pool
    zero w_k along stored pattern; w_k[prow[p]] = vals[p] for p in A[:,q[k]]

  for L in levels:                       # sequential over levels — the chain
    launch kernel over columns k in L:   # block per column (cluster-parallel)
      for p in up[k] .. up[k+1]:         # stored topological order — replay,
        i = ui[p]                        # no DFS, no pivot search on device
        uki = w_k[i]; ux[p] = uki
        parfor threads t over lp[i]..lp[i+1]:      # subcolumn saxpy: the
          atomic/none: w_k[li[t]] -= lx[t] * uki   # per-entry parallelism
      d = w_k[k];  if d == 0: flag singular, abort grid
      udiag[k] = d
      parfor t over lp[k]..lp[k+1]: lx[t] = w_k[li[t]] / d
    grid barrier                         # cooperative launch, like arp_solve

batched solves (Newton RHS per sweep point / MC sample):
  parfor batch b:                        # each b = independent rhs
    forward/back substitution is sequential in k per batch;
    parallelism = across batches + across entries of each saxpy
```

Notes tying to our code:

- Batched RHS is the natural GPU win for us: sweeps (`dc`/`mc`/`temp`) and
  periodic problems produce many independent solves on one factorization —
  `src/gpu_solver.zig` already ships whole Newton solves per cooperative
  launch; a batched substitution kernel drops in beside `arp_solve`.
- Level-set numeric refactor needs *no* pivot search on device precisely
  because `direct.zig` stores the U pattern in solve order and replays the
  pivot sequence (`refactor`); the CPU pivot-collapse fallback (full
  re-factor with fresh pivoting) stays host-side.
- Per-column dense workspaces are the memory cost: a pool of `n`-sized
  slices for the widest level, allocated once (GLU caps parallel columns by
  available global memory; same knob for us).

---

**Sources fetched:** Palamadai Natarajan, *KLU — A High Performance Sparse
Linear Solver for Circuit Simulation Problems*, M.S. thesis, U. Florida 2005
(fetched: https://ufdcimages.uflib.ufl.edu/UF/E0/01/17/21/00001/palamadai_e.pdf
— §§2.1–2.4, 2.9, 2.13, 3.2 read in full); GLU3.0 paper arXiv:1908.00204
(fetched, for the level-set framing in §4).

**Verification status:** §1 factorization/reach/topological-order/complexity —
source-verified against thesis §§2.3–2.4 (eqs. 2–9..2–22). §1 growth bound
$|l| \le 1/\tau$ — derived, not source-verified (standard threshold-pivoting
result; thesis §2.9 states the rule, not the bound). §2 — source-verified
(thesis §§2.2, 2.13, ch. 3 benchmarks). §3 — verified against our
implementation directly. §4 — level-set structure source-verified against
GLU3.0 paper; the batched-solve section is our own design, not from a source.

**Our implementation:** `modules/solvers/src/direct.zig` (`Lu.factor`,
`Lu.refactor`, `Lu.solve/solveT`); ordering consumed from
`modules/solvers/src/order.zig`; Newton caller in
`modules/analysis/src/helper/converger.zig`. Scaling fixtures:
`benchmark/fixtures/scaling/rc_ladder_{1k,10k,100k}`, `rc_mesh_{1k,10k}`,
`resistor_grid_100x100` (fill/ordering stress), `inverter_chain_{256,1k,4k}`
(refactor hot path).
