# Block Triangular Form: Maximum Transversal + Tarjan SCC

## 1. Mathematical specification

**Goal.** Find permutations $P', Q'$ such that

$$P' A Q'^T =
\begin{bmatrix}
A_{11} & A_{12} & \cdots & A_{1b} \\
       & A_{22} & \cdots & A_{2b} \\
       &        & \ddots & \vdots \\
       &        &        & A_{bb}
\end{bmatrix}$$

is block *upper* triangular with irreducible square diagonal blocks
$A_{ii}$. Consequences (thesis §2.6): (i) the sub-diagonal region needs no
factorization work; (ii) only diagonal blocks are factored, independently;
(iii) off-diagonal blocks generate **zero fill** — they enter only the
block back-substitution. The BTF of a matrix is essentially unique (the
Dulmage–Mendelsohn decomposition fixes the blocks up to ordering within the
condensation's topological order; derived, not source-verified).

**Stage 1 — maximum transversal (unsymmetric permutation).** A transversal
is a set of nonzeros, no two sharing a row or column, placed on the
diagonal by a row permutation. Duff's algorithm (thesis §2.5) finds a
maximum one via augmenting paths: model rows as vertices; from an
unassigned row $i_0$ DFS along nonzeros $(i_k, j_{k+1})$ where
$(i_{k+1}, j_{k+1})$ is currently assigned, until reaching a nonzero
$(i_k, j_{k+1})$ with column $j_{k+1}$ unassigned; flip assignments along
the path (an augmenting path / "reassignment chain") to grow the
transversal by one. This is exactly maximum bipartite matching. A full
transversal exists iff $A$ is not structurally singular (Hall's theorem on
the row/column bipartite graph; equivalence stated in thesis §2.5).
Worst-case $O(n \cdot \tau)$ with $\tau = \mathrm{nnz}(A)$; in practice
$O(n + \tau)$.

**Stage 2 — symmetric permutation to BTF (Tarjan SCC).** With a zero-free
diagonal, take the directed graph $G$ with an edge $j \to i$ iff
$A_{ij} \ne 0$, $i \ne j$. Finding a symmetric permutation to BTF is
equivalent to finding the strongly connected components of $G$: each SCC is
one irreducible diagonal block, and the condensation (the DAG of SCCs)
ordered topologically gives the block order. Tarjan's algorithm computes
all SCCs in one DFS pass:

$$\mathrm{low}(v) = \min\bigl(\mathrm{num}(v),\ \min_{(v,w),\, w\ \text{on stack}} \mathrm{num}(w),\ \min_{w\ \text{child}} \mathrm{low}(w)\bigr),$$

$v$ is an SCC root iff $\mathrm{low}(v) = \mathrm{num}(v)$; on detecting a
root, pop the vertex stack down to $v$ — that set is one component. SCCs
emit in **reverse topological order** of the condensation. Complexity
$O(n + \tau)$ (thesis §2.6, Duff & Reid's implementation of Tarjan).

**Why the diagonal must be zero-free first:** a structurally full diagonal
guarantees every vertex has a self-loop-equivalent matching, making the SCC
decomposition of $G$ correspond exactly to the irreducible blocks; without
it the "blocks" of an arbitrary pattern are not square.

**Solve.** With scaling $R$, factored blocks $L_iU_i$ and off-diagonal part
$F$ (thesis eqs. 3–1..3–10):

$$(LU + F)\,Q^T x = P R\, b,$$

solved by block back-substitution: solve the last block
$L_bU_b X_b = B_b$, eliminate $X_b$ from all earlier block equations
through $F$, repeat upward; finally un-permute $x = Q(\cdot)$.

## 2. Flow explanation

Phases: (1) transversal (only if the diagonal may have structural zeros),
(2) one iterative Tarjan DFS over the CSC pattern, (3) per-block
fill-reducing ordering + factorization, (4) block back-substitution at
solve time.

Our variant (`order.zig`): the pattern-merge step of circuit compilation
**guarantees a structurally full diagonal** (every MNA row gets its diagonal
slot stamped), so the identity transversal is already maximum and stage 1
is skipped entirely — documented as a precondition in the module header.
Tarjan runs iteratively (explicit `frame_v`/`frame_p` stacks — no
recursion, same rationale as the factorization DFS), emits SCCs into
`emit[]` with `block_ptr[]` boundaries in reverse topological order, and
each block's sub-pattern is extracted (columns restricted to in-block rows)
and handed to AMD. Singleton blocks pass through — for circuit matrices
most blocks are singletons plus one large block (thesis §3.4: "BTF is not
able to find many blocks... a single large block and the remaining are
singletons"); the payoff is dense source rows/columns peeled into
singletons and the fill-free off-diagonal region.

Note our factorization consumes only the column order `q` — off-diagonal
entries stay inside the single flat factorization rather than a separate
$F$ block-solve. That is a simplification relative to full KLU: correctness
is unchanged (the ordering still confines pivots and most fill within
blocks), but off-diagonal entries can in principle receive fill that KLU's
block-partitioned storage structurally forbids. BTF's ordering benefit is
retained; the storage benefit is approximated.

When BTF wins: block-triangularizable systems (circuits with unidirectional
signal flow, source-driven partitions). When it does nothing: fully
irreducible matrices (one SCC), where `order()` degenerates to plain AMD at
$O(n+\tau)$ wasted preprocessing — an acceptable constant.

## 3. Pseudo-code, CPU sequential

Matches `order.zig order()` (u32, caller-workspace bump allocator, no heap):

```
btf_order(n, col_ptr, row_idx, q):
  # precondition: structurally full diagonal (pattern merge guarantees it)
  # ---- iterative Tarjan over edges j -> row_idx[p], p in col_ptr[j].. ----
  num[*] = NONE; sp = fp = counter = 0; nb = 0
  for root in 0..n where num[root] == NONE:
    visit(root): num=low=counter++, push on scc_stack, on[root]=1,
                 push frame (v=root, p=col_ptr[root])
    while fp > 0:
      v = frame_v[top]
      if frame_p[top] < col_ptr[v+1]:            # scan next child
        child = row_idx[frame_p[top]++]
        if child == v: continue                  # ignore self loop
        if num[child] == NONE: visit(child)      # tree edge: push frame
        elif on[child]: low[v] = min(low[v], num[child])   # back edge
      else:                                      # v finished
        if low[v] == num[v]:                     # v is an SCC root
          pop scc_stack down to v -> emit[], on[.]=0
          block_ptr[++nb] = emitted count        # one block closed
        pop frame; low[parent] = min(low[parent], low[v])
  # blocks now in reverse topological order of the condensation:
  # a sink block (depends on nothing later) is factored FIRST

  # ---- per-block fill ordering ----
  for b in 0..nb:
    verts = emit[block_ptr[b] .. block_ptr[b+1]]
    if |verts| == 1: q[lo] = verts[0]; continue  # singleton passes through
    extract sub-pattern: columns of verts restricted to rows in block b
    amd(sub) -> local order; q[lo..hi] = verts[local order]
```

Maximum transversal (not implemented — precondition makes it dead code;
kept here as the reference algorithm):

```
max_transversal(A):
  match[*] = unassigned
  for each unassigned row i0:
    DFS over alternating paths: nonzero (i,j) with j unassigned -> augment;
    else recurse into the row currently assigned to j (cheap-assignment
    first, then depth-first augmentation)
    flip assignments along the found augmenting path
  structurally singular iff some row stays unassigned
```

## 4. Pseudo-code, GPU parallel

Both stages are pointer-chasing graph algorithms over tiny data
($O(n+\tau)$ once per pattern, microseconds at circuit sizes): they stay on
the CPU in any sane design, ours included. What the GPU consumes is the
BTF *result*:

```
# setup (CPU, once): btf_order -> q, block_ptr
# device layout (SoA, u32): per-block column ranges; per-block LU arrays

gpu_block_factor(blocks):
  # Level 1 parallelism — blocks are mutually independent:
  parfor block b:                        # stream / block-cluster per SCC
    level-set numeric refactor of A_bb   # see gpu-sparse-lu.md
  # no synchronization between blocks at factor time at all

gpu_block_solve(x):
  for b in reverse block order:          # SERIAL: condensation chain
    solve L_b U_b X_b = B_b              # batched tri-solve within block
    parfor off-diagonal entries F[:, block b]:
      B_earlier -= F * X_b               # SpMV update, fully parallel
```

What fundamentally serializes: the block back-substitution follows the
condensation DAG — topological depth of the block graph is a hard lower
bound on solve steps, exactly like column levels inside one block. Factor
time, by contrast, is embarrassingly parallel across blocks; BTF is
therefore *more* valuable on GPU than on CPU (it manufactures coarse-grain
independent work that level sets alone cannot). For our megakernel: blocks
map to independent thread-block groups inside one cooperative launch, grid
barrier only between solve levels of the condensation.

---

**Sources fetched:** Palamadai Natarajan thesis (fetched, §§2.5–2.6, 3.1–3.4,
eqs. 3–1..3–10); GLU3.0 paper arXiv:1908.00204 (fetched, MC64+AMD
preprocessing flow, fig. 5).

**Verification status:** §1 transversal/Tarjan/complexities/solve equations —
source-verified against thesis §§2.5–2.6, ch. 3. §1 Dulmage–Mendelsohn
uniqueness remark — derived, not source-verified (standard result, Davis
*Direct Methods* is the paywalled reference). §2/§3 — verified against
`order.zig` directly; the flat-storage deviation from KLU's block storage is
our reading of our own code. §4 — derived, not source-verified (design
reasoning; GLU papers do per-matrix, not per-block, GPU scheduling).

**Our implementation:** `src/analysis/solvers/order.zig` (`order()` = iterative
Tarjan + per-block AMD; workspace `Ws`), consumed by
`src/analysis/solvers/direct.zig` `Lu.init`. Scaling fixtures:
`benchmark/fixtures/scaling/divider_chain` (deep condensation),
`parallel_inverters_{100,500,2000}` (many independent blocks),
`resistor_grid_32x32` vs `resistor_grid_100x100` (single irreducible block —
BTF-neutral baseline).
