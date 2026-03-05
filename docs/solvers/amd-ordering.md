# AMD — Approximate Minimum Degree Ordering

## 1. Mathematical specification

**Objective.** Find a permutation $P$ minimizing fill in the Cholesky-like
factorization of $PAP^T$ (of $P(A + A^T)P^T$ when $A$ is unsymmetric —
thesis §2.8). A fill-in is $L_{ij} \ne 0$ where $A_{ij} = 0$. Minimum-fill
ordering is NP-complete (thesis §1), so all practical orderings are
heuristics on the *elimination graph* model:

Represent the (symmetrized) pattern as an undirected graph $G(V,E)$,
$\{i,j\} \in E \iff A_{ij} \ne 0$. Eliminating vertex $p$ deletes $p$ and
adds edges to make its neighborhood a clique (thesis §2.8, figs. 2–4/2–5);
each added edge is one fill-in. The **minimum degree** rule greedily picks
the vertex of smallest current degree each step — a vertex of degree $d$
creates at most $\binom{d}{2}$ fill edges, so small degree bounds fill per
step (greedy bound only: no global optimality guarantee).

**Quotient graph.** Explicit elimination graphs grow ($O(n^2)$ worst
case). The quotient graph represents them in $O(\mathrm{nnz}(A))$ space
throughout: vertices are *variables* (uneliminated) and *elements*
(eliminated pivots); variable $i$ carries an adjacency of variables
$\mathcal{A}_i$ and of elements $\mathcal{E}_i$; element $e$ carries its
member set $L_e$ (the pattern of the corresponding column of $L$). The
elimination-graph neighborhood of $i$ is implicitly

$$\mathrm{Adj}_G(i) = \Bigl(\mathcal{A}_i \cup \bigcup_{e \in \mathcal{E}_i} L_e\Bigr) \setminus \{i\}.$$

Eliminating $p$: form $L_p = \mathrm{Adj}_G(p)$, make $p$ an element,
absorb all elements $e \in \mathcal{E}_p$ into $p$ (their $L_e \subseteq
L_p \cup \{p\}$ makes them redundant — *element absorption*), and prune
each member $i \in L_p$: $\mathcal{A}_i \gets \mathcal{A}_i \setminus (L_p
\cup \{p\})$, $\mathcal{E}_i \gets (\mathcal{E}_i \setminus \text{dead})
\cup \{p\}$.

**Approximate degree (the "A" in AMD).** True external degree
$d_i = |\mathrm{Adj}_G(i)|$ requires set unions. Amestoy–Davis–Duff replace
it with the upper bound

$$\bar d_i = \min\Bigl( n - k,\ \ d_i^{\text{prev}} + |L_p \setminus i|,\ \ |\mathcal{A}_i \setminus L_p| + |L_p \setminus i| + \sum_{e \in \mathcal{E}_i \setminus p} |L_e \setminus L_p| \Bigr)$$

where the terms $|L_e \setminus L_p|$ are computed for **all** elements in
one scan of the members of $L_p$ (initialize $w_e = |L_e|$, subtract
$|\text{supervariable } i|$ for each member $i$ of $L_p$ adjacent to $e$;
the leftover $w_e$ is exactly $|L_e \setminus L_p|$). This makes the whole
degree update cost proportional to quotient-graph edges scanned, giving
AMD's $O(\mathrm{nnz} \cdot \text{small factor})$ practical complexity, and
$\bar d_i \ge d_i$ always (overestimate — safe for the greedy rule).
Elements with $w_e = 0$ satisfy $L_e \subseteq L_p$ and are absorbed
(*aggressive absorption*).

**Supervariables.** Variables $i, j$ with identical closed adjacency
($\mathcal{A}$ and $\mathcal{E}$ sets equal) are *indistinguishable*:
eliminating one immediately makes the other minimum-degree. Merge them
($nv_i \mathrel{+}= nv_j$, $nv_j = 0$); detect candidates cheaply by
hashing $\sum \mathcal{A}_i + \sum \mathcal{E}_i$ and comparing only within
hash buckets. Supervariables shrink the graph and let one pivot step emit
whole index sets.

**Mass elimination & dense rows.** A merged supervariable of size $nv$
emits $nv$ consecutive pivots at once. Rows denser than a threshold
($10\sqrt{n}$ classical) are withheld from the graph and appended last —
they would otherwise pollute every degree update at quadratic cost while
inevitably being ordered last anyway.

## 2. Flow explanation

One phase, purely symbolic, run once per pattern (per BTF block for us):

1. **Build** the symmetrized variable adjacency from CSC (both $A_{ij}$ and
   $A_{ji}$ edges), dedup, detect dense rows, initialize degree lists.
2. **Main loop** ($k$ from 0): pop a minimum-degree variable $p$ from the
   degree buckets, form $L_p$ through the quotient-graph identity, kill
   absorbed elements, compute $w_e$ bounds in one scan, prune each member's
   adjacencies, recompute approximate degrees capped at $n_{\text{amd}} - k
   - nv_p$, hash-and-merge supervariables, reinsert members into degree
   buckets, emit $p$ and its merged chain into `q`.
3. **Tail:** append dense rows.

Data structures (ours, `order.zig amd()`): degree buckets as doubly-linked
lists (`head/next/prev`) for $O(1)$ pop/remove — minimum degree only ever
decreases by bounded amounts so a rising `mindeg` scan is amortized $O(n)$;
variable adjacency `va[]` as **contiguous packed** spans (pointer+len per
vertex) rather than linked slabs — sequential scans, at the cost of
relocating element-adjacency spans `ea[]` on growth (bump-allocated,
2× growth, `OutOfWorkspace` on exhaustion → caller retries with a bigger
slab); element member lists $L_e$ appended to the `va[]` tail; epoch marks
(`mark/wmark`) instead of clearing; merged chains linked through `mlink`.
Everything lives in one caller-provided `u32` slab (`wsSize(n,nnz) = 48n +
8·nnz + 64`) so the identical code runs at comptime, runtime, and under the
emitter.

Where AMD wins: nearly-symmetric patterns — precisely what BTF blocks of
circuit matrices are (thesis §3.1: block patterns are *more* symmetric than
the original). Thesis tables 3–4/3–5: BTF+AMD beats AMD alone, MMD, and
COLAMD on fill for circuit matrices (e.g. Sandia/mult_dcop_01: 227k fill
for BTF+AMD vs 2.18M for plain AMD). COLAMD targets $A^TA$-like patterns
(unsymmetric with pivoting) and consistently over-fills on circuits.

## 3. Pseudo-code, CPU sequential

Condensed from `order.zig amd()` (which is the reference for details like
relocation and hashing):

```
amd(n, col_ptr, row_idx, q, ws):
  build symmetrized packed adjacency va (dedup by epoch mark)
  defer rows with |adj| >= max(16, 10*floor(sqrt(n))) to the tail (nv=0)
  deg[i] = |va_i|; insert all live i into degree buckets

  k = 0
  while k < n - ndense:
    p = pop head of lowest nonempty degree bucket

    # Lp = (A_p ∪ ⋃ Le for e in E_p) \ p     — quotient graph identity
    Lp = unique live members of va_p and of va_e for live e in ea_p
    kill those elements; nv_p becomes 0; p becomes element with L_p = Lp
    esize[p] = Σ nv_i over Lp;  remove Lp members from degree buckets

    # |Le \ Lp| bounds in ONE scan of Lp's element adjacencies
    for i in Lp: for live e in ea_i:
      first touch: w[e] = esize[e]
      w[e] -= nv_i
    absorb (kill) every e with w[e] == 0            # aggressive absorption

    for i in Lp:
      ea_i = live(ea_i) ∪ {p}      (relocate span if full; esum = Σ w[e])
      va_i = va_i \ (Lp ∪ dead)    (asum = Σ nv over survivors)
      deg[i] = min(asum + (|Lp|_weighted - nv_i) + esum,  n_amd - k - nv_p)

    # supervariable merge: hash Σ(va_i)+Σ(ea_i), compare within buckets
    for equal-adjacency pairs (i,j): nv_i += nv_j; nv_j = 0; chain j on mlink_i
    reinsert live Lp members into degree buckets; track mindeg

    emit q[k++] = p, then every vertex on p's mlink chain (mass elimination)

  append deferred dense rows to q
```

## 4. Pseudo-code, GPU parallel

Honest answer first: **AMD does not belong on the GPU.** It is a serial
greedy heuristic — each pivot choice depends on all previous updates; the
"work" is irregular pointer-chasing over a mutating graph; and it runs
*once per pattern* while factor/solve run millions of times. Amdahl kills
any conceivable win. Parallel-ordering literature replaces the algorithm
(nested dissection via parallel graph partitioning) rather than
parallelizing MD. What a GPU pipeline actually does:

```
gpu_ordering_strategy(pattern):
  # once, on CPU, at compile/init time (our Path A/B):
  q = btf_amd(pattern)                    # order.zig, microseconds at our n
  symbolic factor -> lp/li, up/ui, levels # frozen pattern for the device

  # the GPU consumes q only through the frozen pattern:
  upload SoA CSC + level sets once; refactor/solve forever after

# if ordering ever became the bottleneck (it is not: analysis-time
# dominance in thesis table 3-6 is amortized over ALL refactors):
alternative: nested dissection per BTF block
  parfor separator levels: graph bisection (parallelizable)  # ND, not MD
  leaves ordered by (CPU) AMD             # hybrid, as thesis §2.16 suggests
```

The one ordering choice that *matters* for the GPU is fill vs level count:
lower fill (AMD's objective) shortens each level's work but can deepen the
column-dependency DAG; nested dissection yields shallower, wider DAGs —
better level-set parallelism at somewhat higher fill. Worth measuring only
if GPU factorization (not refactor-replay) becomes our hot path — for
refactor-replay the DAG is fixed by the CPU factorization anyway.

---

**Sources fetched:** Palamadai Natarajan thesis (fetched — §§2.8, 3.4–3.6,
tables 3–3..3–8: ordering comparisons, phase timings); SuiteSparse AMD is the
reference implementation (repository known, paper "An Approximate Minimum
Degree Ordering Algorithm", Amestoy–Davis–Duff 1996, paywalled SIAM).

**Verification status:** §1 elimination-graph model, MD rule, AMD-vs-MMD/
COLAMD behavior — source-verified against thesis §§2.8, 3.4–3.6. §1 quotient
graph identity, approximate-degree bound, $w_e$ one-scan trick, aggressive
absorption, supervariable hashing, dense-row threshold — derived, not
source-verified (from the AMD paper's known content and our implementation;
the thesis describes these only at survey level). §2/§3 — verified against
`order.zig` directly. §4 — derived, not source-verified (engineering
judgment; no source parallelizes MD on GPU).

**Our implementation:** `src/analysis/solvers/order.zig` (`amd()`, `DegLists`,
`Ws`, `wsSize`); consumed per BTF block by `order()` and by
`src/analysis/solvers/direct.zig` `Lu.init` (`Params.ordering = .amd`).
Scaling fixtures: `benchmark/fixtures/scaling/rc_mesh_{1k,10k}` and
`resistor_grid_{32x32,100x100}` (2-D patterns where ordering quality
dominates fill), `rc_ladder_100k` (chain — near-zero fill sanity bound).
