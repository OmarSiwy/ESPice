# GPU Sparse LU: GLU 3.0 Level Sets, NICSLU Parallelism

## 1. Mathematical specification

**The dependency structure.** In left-looking LU, column $j$ depends on
column $i < j$ iff $U(i,j) \ne 0$ (the triangular solve for column $j$
reads $L(:,i)$ — GLU3.0 §II-C). These edges form a DAG over columns.
**Levelization** partitions columns into *levels*

$$\mathrm{level}(j) = 1 + \max_{\,i \in \mathrm{dep}(j)} \mathrm{level}(i), \qquad \mathrm{level}(\text{leaf}) = 0;$$

all columns in one level are mutually independent and factorable in
parallel. The DAG depth (≈ elimination-tree height for symmetric patterns)
is the hard serialization bound: no schedule beats
$\Omega(\text{depth})$ sequential steps. Levelization requires the *filled*
pattern, so symbolic analysis (fill computation) runs first — on the CPU,
without numerical pivoting (GLU flow, fig. 5: MC64 for a strong zero-free
diagonal as a static-pivoting substitute, then AMD, then fill-in +
levelization, then GPU numeric factorization).

**Hybrid right-looking reformulation (GLU 1.0–3.0).** Pure left-looking
serializes the triangular solve (Algorithm 1 lines 4–8: the outer $k$ loop
of MACs writes one column while scanning it). GLU restructures: once
column $j$ is normalized ($A(k,j) \mathrel{/}= A(j,j)$ for $k > j$),
immediately update all *subcolumns* — columns $k > j$ with $A(j,k) \ne 0$
(GLU3.0 Algorithm 2). The submatrix update is a sparse rank-1 tensor
operation (GLU3.0 eq. 2):

$$A_{sub} \gets A_{sub} - \begin{bmatrix} A(j{+}1,j) \\ \vdots \\ A(n,j)\end{bmatrix}
\cdot \bigl[A(j,j{+}1), \cdots, A(j,n)\bigr],$$

executed column-wise: $\vec A(j{+}1{:}n, i) \mathrel{-}=
\vec A(j{+}1{:}n, j)\, A(j,i)$ for each subcolumn $i$. Two nested levels of
parallelism: (a) subcolumns of a column in parallel, (b) MAC per element in
parallel — versus left-looking's element-level-only parallelism.

**Double-U dependency and its relaxed detection (GLU3.0 §II-C, §III-A).**
Right-looking updates introduce a read-write hazard absent from the U
pattern: if $A(t,k)$ is *updated* by column $i$ ($A(i,k) \ne 0$, $A(t,i)
\ne 0$) and also *read* by column $t$'s own updates, columns $i$ and $t$
need an ordering edge even when $U(i,t) = 0$. GLU2.0 detected these exactly
in $O(n^3)$ (Algorithm 3, triple loop) — dominating preprocessing. GLU3.0's
*relaxed* rule: a necessary condition for the extra dependency is a nonzero
**left of the diagonal in row $k$ of $L$**; so add edges $i \to k$ for all
$A_s(k,i) \ne 0$, $i < k$ ("look left"), on top of the classical "look up"
($A_s(i,k) \ne 0$ in $U$). Superset of the exact dependencies, possibly
redundant — but level *count* barely changes (GLU3.0 table II) while
detection drops to two loops: 8804× (arith. mean) faster levelization,
identical numerics.

**Resource assignment across levels (GLU3.0 §III-B).** Empirically levels
fall into three types: **A** — early: thousands of parallel columns, few
subcolumns each; **C** — late: few columns, huge subcolumn counts (the
dense-ish trailing submatrix); **B** — transition. Column count and
subcolumn count per level are *inversely correlated*, so level size is the
resource-allocation signal:

- *small block mode* (type A): one block per column, warps per block grown
  as $W = \lceil \text{total warps} / \text{level size} \rceil$ (2→4→8→32),
  one warp per subcolumn; max parallel columns capped by memory
  $N = M_{\max} / (n \cdot \mathrm{sizeof(float)})$ (each in-flight column
  scatters into a dense length-$n$ cache);
- *large block mode* (type B): one block per column, up to 32 warps;
- *stream mode* (type C, level size ≤ 16): a *block* (not warp) per
  subcolumn, kernel launch per column across ~16 CUDA streams.

Reported results: 13.0×/6.7× (arith/geo mean) over GLU2.0, ≥5× typical;
warp occupancy ~80% in block modes vs ~40% in stream mode (sparsity
mismatch); GLU uses single precision on Maxwell (no double atomics) —
double expected ~30% slower on newer parts.

**NICSLU parallelism (README + cited papers).** CPU multicore counterpart:
levelization by elimination tree; **cluster mode** for wide levels (columns
dealt to threads, no synchronization inside a level) and **pipeline mode**
for narrow/deep level tails — thread $t$ starts column $j{+}t$'s updates
speculatively as the columns it depends on finish one by one, overlapping
the dependency chain instead of barriering per level. Adaptive: chooses
factor-with-pivoting vs refactor-without per call based on runtime history
(details beyond the README: derived, not source-verified — from the cited
TCAD 2013 paper's known content). NICSLU is superseded by CKTSO (same
author) — noted for the open-questions list.

## 2. Flow explanation

Phases of a GLU-style solver:

1. **CPU preprocessing (once per pattern):** MC64 zero-free-diagonal +
   scaling (static pivoting — replaces per-column partial pivoting, which
   would invalidate the precomputed pattern), AMD, symbolic fill (the
   filled pattern $A_s$ holds L and U in one CSC-with-fill structure),
   levelization with relaxed double-U detection.
2. **Upload once:** filled pattern (SoA CSC), level buckets, values.
3. **GPU numeric factorization (every Newton iteration):** for each level,
   pick kernel mode by level size, launch: normalize column(s), then
   right-looking subcolumn updates. Grid-sync between levels.
4. **Solve:** either on GPU (level-scheduled triangular solves — the same
   DAG transposed) or downloaded and done on CPU (GLU does CPU solve;
   factor dominates).

Divergence from our CPU design, and why it matters for porting: GLU
*replaces* pivoting with MC64 static pivoting + fill from the no-pivot
pattern; our `direct.zig` factors with threshold pivoting on the CPU once
and *replays* the pivot sequence — the GPU work we'd ship is the
**refactor**, which needs no pivot search either. Both approaches keep all
pivot decisions off the device; ours keeps KLU's numerics (τ-threshold on
real values) at the cost of a CPU full-factor whenever the pivot monitor
trips (see `klu-pipeline.md`). Our layout is already GPU-shaped: SoA CSC,
u32 indices, `up/ui` stored in topological (solve) order, allocate-once
workspaces, and stable slot addressing via `prow`.

When GPU LU wins: many refactor+solve cycles on one pattern (transient
Newton), matrices large enough that level width × subcolumn work saturates
the device (GLU's wins start ~80k rows; below that, driver overhead ~40% of
GPU time — table I, ASIC_100ks discussion). When it loses: small circuits
(launch overhead), deep-narrow DAGs (ladders — level width 1 ⇒ pure serial
chain on slower cores; our tridiag path is the honest answer there), and
any flow needing per-iteration re-pivoting.

## 3. Pseudo-code, CPU sequential

The reference algorithms GLU parallelizes (GLU3.0 Algorithms 1–2, on the
symbolically filled matrix $A_s$; compare `gilbert-peierls-lu.md` §3 for
our pivoting variant):

```
left_looking(As):                       # G/P without pivoting, filled pattern
  for j in 1..n:
    for k < j where As(k,j) != 0:       # triangular solve, topo order
      for i > k where As(i,k) != 0:
        As(i,j) -= As(i,k) * As(k,j)    # MAC
    for i > j where As(i,j) != 0:
      As(i,j) /= As(j,j)                # normalize -> L column

hybrid_right_looking(As):               # GLU's reformulation
  for j in 1..n:
    for k > j where As(k,j) != 0: As(k,j) /= As(j,j)     # L column first
    for k > j where As(j,k) != 0:       # subcolumns of j
      for i > j where As(i,j) != 0:
        As(i,k) -= As(i,j) * As(j,k)    # submatrix (rank-1) update

levelize_relaxed(As):                   # GLU3.0 Algorithm 4, two loops
  for k in 1..n:
    for i < k where As(i,k) != 0 and column i of L nonempty:
      dep[k] += i                       # classical "look up" (U pattern)
    for i < k where As(k,i) != 0:
      dep[k] += i                       # relaxed "look left" (L row) —
                                        # covers double-U, maybe redundant
  level[k] = 1 + max(level[dep[k]]), leaves 0; bucket by level
```

## 4. Pseudo-code, GPU parallel

Aligned with our data layout (SoA CSC, u32, `NONE` sentinel, allocate-once;
grid-sync = cooperative launch as in `src/gpu_context.zig`):

```
# device residents (allocated once): col_ptr/row_idx of the FILLED pattern,
# vals plane, level_ptr/level_cols (CSR-of-levels), per-column dense cache
# pool w[N][n] with N = mem-capped parallel columns, fail_flag

kernel factor_level(level L, mode):
  mode small_block:                     # type A: many cols, few subcols
    block b <- column j = level_cols[level_ptr[L] + b]
    warp w  <- subcolumn i_w of j       # A(j,i) != 0, i > j
    lanes   <- entries of subcolumn:    # MAC per nonzero
      As(i,k) -= As(i,j) * As(j,k)      # gather through row_idx, u32
  mode large_block:                     # type B: same, up to 32 warps/block
  mode stream:                          # type C: few cols, huge subcols
    kernel launch <- column (one of <=16 streams)
    block <- subcolumn; threads <- entries

host loop (or single cooperative kernel with grid barriers):
  upload vals (one HtoD; header-only when values live on device already)
  for L in levels:
    mode = size(L) > A_thresh ? small_block
         : size(L) > 16       ? large_block : stream
    launch factor_level(L, mode)        # normalize cols of L, then updates
    grid barrier / stream sync
  download status (+ x after solve)     # one DtoH, mirrors arp_solve

# our refactor-replay variant (pivot sequence frozen by CPU factor):
kernel refactor_level(L):
  block <- column k in L
    zero stored pattern of k in w_k; scatter vals through prow[]
    for p in up[k]..up[k+1]:            # stored topological order
      i = ui[p]; uki = w_k[i]; ux[p] = uki
      parfor lanes t in lp[i]..lp[i+1]: w_k[li[t]] -= lx[t] * uki
    d = w_k[k]; monitor growth; udiag[k] = d
    parfor t in lp[k]..lp[k+1]: lx[t] = w_k[li[t]] / d

batched triangular solves (the part GLU leaves on CPU):
  parfor rhs b in batch:                # sweeps / MC samples / harmonics
    level-scheduled L then U solve; entries of each column's saxpy parfor
  # single-rhs solve on GPU is latency-bound: DAG depth * barrier cost —
  # only batching amortizes it

what fundamentally serializes, and why:
  1. level chain — column j cannot start before dep(j) finished writing
     the values it reads; DAG depth is a lower bound (data dependence).
  2. within stream mode, the trailing columns approach dense LU with
     rank-1 updates — parallelism narrows to one column's subcolumns.
  3. pivot search (if done honestly on values) is a global argmax +
     pattern rewrite per column — why every GPU LU (GLU: MC64 static;
     ours: CPU-frozen sequence) removes it from the device.
  4. launch/driver overhead per level — GLU measures it at up to 40% of
     GPU time for ~100k-row matrices; batching levels into one cooperative
     kernel with grid barriers (our megakernel pattern) is the mitigation.
```

---

**Sources fetched:** GLU3.0 paper, Peng & Tan, arXiv:1908.00204 (fetched in
full — algorithms 1–5, eq. 1–5, figs. 5/10/11, tables I–III);
GLU_public README (fetched — github.com/sheldonucr/GLU_public; note the
repo moved from the GLU3.0 URL in RESEARCH.md, and its README documents
2026 bug fixes incl. a divergent-`__syncthreads` deadlock in
`RL_onecol_updateSubmat` — worth remembering if we ever port their
kernels); NICSLU README (fetched — github.com/chenxm1986/nicslu;
successor pointer to CKTSO).

**Verification status:** §1 levelization, hybrid right-looking, double-U +
relaxed detection, three kernel modes, W/N formulas, all performance
numbers — source-verified against the GLU3.0 paper. §1 NICSLU cluster/
pipeline modes — README is thin; details drawn from the cited Chen/Wang/Yang
TCAD 2013 paper as known content: derived, not source-verified. §2 —
source-verified (GLU fig. 5 flow) + our-code reading. §3 — transcribed from
GLU3.0 Algorithms 1/2/4. §4 — GLU parts source-verified; the
refactor-replay variant and batched-solve design are ours, not from a
source.

**Our implementation:** none yet on-device for LU — this doc is the port
spec. Host pieces it would reuse: `src/solvers/direct.zig` (frozen
pattern, `up/ui` topo order, `prow`, growth monitor),
`src/gpu_context.zig` (cooperative-launch driver, staged prefix,
one-HtoD/one-DtoH protocol), `src/solvers/converger.zig`
(fallback ladder the GPU path must respect). Scaling fixtures:
`benchmark/fixtures/scaling/resistor_grid_100x100`, `rc_mesh_10k` (wide
DAGs — level-set friendly), `rc_ladder_100k` (adversarial: depth-n DAG,
GPU should decline), `parallel_inverters_2000` (block-parallel best case).
