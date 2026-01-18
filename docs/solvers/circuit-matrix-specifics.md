# Circuit-Matrix Specifics: Why BTF+AMD Wins, Fast Paths, Signature/Bypass Tricks

## 1. Mathematical specification

**What an MNA matrix is.** Modified nodal analysis yields $A = G + $
branch rows: KCL rows (node conductances, diagonally dominant after gmin:
$|a_{ii}| \ge \sum_{j\ne i} |a_{ij}|$ minus source coupling) plus KVL rows
for voltage-defined branches with **structural zero diagonals**. Properties
(thesis §§1, 3.1):

- extremely sparse: $\mathrm{nnz}(A) = O(n)$, a handful of entries per row;
- values unsymmetric, **pattern nearly symmetric** ($A_{ij} \ne 0
  \Leftrightarrow A_{ji} \ne 0$ for almost all device stamps);
- a few dense rows/columns from voltage/current sources spanning many nodes;
- pattern fixed over the whole simulation, values changing every Newton
  iteration / timestep;
- readily permutable to BTF; the per-block patterns after BTF are *more*
  symmetric than $A$ itself.

**Why BTF+AMD beats general orderings.** Three compounding effects:

1. *Dense-row removal:* BTF peels source rows/columns into singleton blocks
   or the off-diagonal region $F$. Since $F$ is never factored, it
   contributes **zero fill** — whereas a general ordering must schedule
   dense rows late and still eats $\Theta(d^2)$ clique fill from a row of
   degree $d$ when it finally pivots. AMD's dense-row deferral mitigates,
   BTF eliminates.
2. *Fill confinement:* fill can only appear inside diagonal blocks;
   the search space of the NP-hard fill problem factorizes into independent
   subproblems, each smaller and more symmetric — exactly AMD's model
   ($P(A+A^T)P^T$) assumption, so its optimistic estimate tracks reality.
3. *Work restriction:* the block back-substitution does $O(\mathrm{nnz}(F))$
   extra solve work instead of factor work.

Thesis evidence (tables 3–4/3–5): BTF+AMD ≤ AMD ≤ {MMD, COLAMD} in fill on
circuit matrices, with pathological blowups for the general orderings
(mult_dcop_01: 227k vs 2.18M AMD-alone vs 1.46M COLAMD); supernodal codes
(SuperLU/UMFPACK) lose additionally because circuit fill never produces the
dense sub-blocks their BLAS-3 kernels amortize on (table 3–1: KLU 1.5–3×).

**Tridiagonal fast path.** If the pattern satisfies $|i - j| \le 1$ for all
nonzeros, LU without pivoting is the Thomas algorithm:

$$b'_1 = b_1, \quad m_i = a_i / b'_{i-1}, \quad b'_i = b_i - m_i c_{i-1}, \qquad i = 2..n,$$

then one forward sweep ($x_i \mathrel{-}= m_i x_{i-1}$) and one back sweep
($x_i = (x_i - c_i x_{i+1})/b'_i$): $O(n)$ time, $O(n)$ memory, zero fill,
zero symbolic work. Stable without pivoting when $A$ is diagonally dominant
or SPD (derived, not source-verified — standard result); MNA + gmin
satisfies this for RC/RLC ladder topologies, which is exactly where the
pattern occurs. Banded generalizations follow the same recurrence with
bandwidth-$w$ inner loops at $O(nw^2)$.

**Matrix signature / bypass.** Two levels of "the matrix didn't change":

- *Value identity:* if $\mathrm{vals} = \mathrm{vals}_{\text{prev}}$
  elementwise, the existing factorization is exact — an $O(\mathrm{nnz})$
  compare avoids an $O(\mathrm{flops}(LU))$ refactor. Pays off whenever
  assembly is deterministic and the circuit is linear at fixed $(\alpha,
  g_{\min}, \Delta t)$.
- *Symbolic signature:* a caller-provided token $\sigma \ne 0$ asserting
  "same assembled matrix as any other call with this $\sigma$" (linear
  circuit, constant Jacobian, fixed companion coefficients). Then even the
  compare is skipped and Newton reuses the LU across iterations *and*
  timesteps. Invalidation is the caller's contract (new $\sigma$ after any
  model/step-size mutation) — the classic cache trade: cheap hit, dangerous
  stale.

Both are instances of the refactorization theorem (pattern + pivot sequence
frozen ⇒ replay is valid) pushed to its degenerate cases.

## 2. Flow explanation

Dispatch precedence in our `Solver` (init-time, pattern-only decisions):

1. **tridiag** — pattern scan `isTridiag`; if yes, Thomas engine: `a_pos/
   b_pos/c_pos` map CSC slots to the three diagonals once, factor/solve are
   the recurrences above. No pivoting (ponytail-commented ceiling: fine for
   diagonally-dominant MNA + gmin; the fixture set keeps it honest).
2. **BBD** — bordered block diagonal engine when the compiler hands a
   partition (`root.BbdInfo`): per-block dense refactor + Schur border,
   falls back permanently to flat on singularity (`ESPICE_NO_BBD` forces
   flat — A/B switch).
3. **flat KLU-style LU** — everything else (see `gilbert-peierls-lu.md`,
   `klu-pipeline.md`).

Value-bypass sits above all engines in `Solver.factor` (memcmp against
`vcopy`); the symbolic signature sits above the *solver* in
`converger.newton` (`Options.matrix_sig` vs `ws.factored_sig`) — two
distinct caches, deliberately: the memcmp needs no caller contract, the
signature costs nothing per iteration. Off-diagonal-source peeling comes
for free through BTF ordering rather than explicit block storage (see
`btf-permutation.md` for the deviation from full KLU).

When each path wins: tridiag on ladders/chains ($O(n)$ vs $O(n)$-with-
constants — measured ~5–10× on `rc_ladder_100k`-class shapes); BBD when the
netlist has repeated-structure partitions; value-bypass on any linear
circuit between $\Delta t$ changes (transient with fixed step: factor cost
→ one memcmp per step); signature on all-const-Jacobian circuits under
sweeps.

## 3. Pseudo-code, CPU sequential

```
Solver.init(pattern):                    # decisions are PATTERN-ONLY, once
  if n >= 3 and all |row-col| <= 1: engine = Thomas(map 3 diagonals to slots)
  elif bbd_info and Bbd.init succeeds:   engine = BBD
  else:                                  engine = Lu (BTF+AMD ordering)

Solver.factor(vals):
  if factored and memcmp(vcopy, vals[0..nnz]) == 0: return   # value bypass
  engine.factor(vals)  # tridiag: Thomas recurrence, O(n)
                       # bbd: per-block dense factor, Schur border;
                       #      on singularity -> demote to flat Lu forever
                       # lu: refactor, fallback full factor (klu-pipeline.md)
  vcopy = vals[0..nnz]

newton iteration (converger.zig):
  if matrix_sig != 0 and ws.factored_sig == matrix_sig:
    skip factor entirely                 # symbolic signature bypass
  else:
    slv.factor(vals); ws.factored_sig = matrix_sig

thomas_factor(vals):                     # per timestep / Newton iteration
  bp[0] = b[0]; fail if 0 or non-finite
  for i in 1..n:
    m = a[i] / bp[i-1]; mul[i] = m
    bp[i] = b[i] - m * cv[i-1]; fail if 0 or non-finite
thomas_solve(x):
  for i in 1..n:  x[i] -= mul[i] * x[i-1]
  x[n-1] /= bp[n-1]
  for i in n-2..0: x[i] = (x[i] - cv[i] * x[i+1]) / bp[i]
```

## 4. Pseudo-code, GPU parallel

Circuit-specific structure changes what is worth shipping to the device:

```
# tridiagonal on GPU: the Thomas recurrence is serial; the parallel
# alternative is cyclic reduction / PCR:
pcr_solve(a, b, c, x):                  # O(n log n) work, O(log n) depth
  for step in 1..log2(n):               # each step halves coupling distance
    parfor i: eliminate a_i, c_i against rows i±2^(step-1)
    grid barrier
  parfor i: x[i] = rhs[i] / b[i]
# worth it only when n is large AND the solve is on the device critical
# path (our megakernel transient); for host solves Thomas at O(n) wins.

# value bypass on device: memcmp is a parallel reduction —
parfor chunks: local_eq = all(vals[chunk] == vcopy[chunk]); and-reduce
if equal: skip refactor launch entirely  # saves the whole level-set sweep

# signature bypass: pure host logic — zero device cost, decided before
# any launch; matrix_sig lives beside the staged header (gpu_solver.zig
# already patches per-solve headers; the sig is one more u64 compare).

# BBD on GPU: the natural megakernel layout —
parfor blocks b: dense refactor of block b   # batched small dense LU,
                                             # one thread-block each
serial: assemble + factor Schur border       # small dense, one block
parfor blocks b: back-substitute block b against border solution
# BBD's coarse independence is the circuit-specific answer to level-set
# starvation: blocks are large, uniform, and known at compile time.
```

What fundamentally serializes: the Thomas recurrence (each $b'_i$ needs
$b'_{i-1}$ — PCR trades work for depth); the Schur border factor (all
blocks feed it); and, as everywhere, the column DAG of any flat sparse
factor. The circuit-matrix escape hatches are exactly the structures above:
compile-time-known partitions (BBD/BTF) manufacture parallelism that
generic level sets can't.

---

**Sources fetched:** Palamadai Natarajan thesis (fetched — §§1, 3.1, 3.4,
tables 3–1..3–5 for the ordering/solver comparisons); GLU3.0 paper
arXiv:1908.00204 (fetched — confirms MC64+AMD preprocessing as the GPU-side
standard too).

**Verification status:** §1 circuit-matrix properties and BTF+AMD superiority
— source-verified against thesis (properties §3.1, numbers tables 3–1/3–4/
3–5). §1 Thomas algorithm + stability condition, PCR — derived, not
source-verified (standard texts; Davis book paywalled). §1/§2 signature &
bypass — our design, verified against our code (no external source; ngspice
has a related per-device "bypass" option but no matrix-level equivalent).
§3 — verified against `direct.zig`/`converger.zig` directly. §4 — derived,
not source-verified.

**Our implementation:** `modules/solvers/src/direct.zig` (`isTridiag`,
`TriDiag`, `Solver.factor` vcopy bypass, BBD dispatch + demotion),
`modules/solvers/src/bbd.zig`, `modules/analysis/src/helper/converger.zig`
(`Options.matrix_sig`, `Workspace.factored_sig`). Scaling fixtures:
`benchmark/fixtures/scaling/rc_ladder_{1k,10k,100k}` + `rc_chain_500`
(tridiag path), `parallel_inverters_{100,500,2000}` (BBD partitions),
`divider_chain` (signature/bypass on linear sweep),
`benchmark/fixtures/bypass/` (bypass correctness).
