# RESEARCH.md — reference specs we implement against

Drop specs (PDF/URL) here or in `dep/specs/`, point at one, it gets implemented
against a bench fixture. Workflow: spec (intent) + reference source (bit-exact
behavior) → diff vs our impl → minimal fix → `zig build bench -- --filter CAT/NAME`.

This list grows — add links as found.

---

## 1. Devices

**Looking for:** exact model equations (temp scaling, all bias regions,
junction limiting, node collapse rules) for anything failing accuracy in
`benchmark/REPORT.md`, and specs for models we don't have yet.

Current wants, priority order:
- **B4SOI 4.4** full spec — devices/b4soi FAILs (we map to b3soipd cognate, 3.2e-1)
- **BSIMPD/B4SOI generation deltas** — b3soipd rms 7.5e-3 is model-generation skew
- **LTRA convolution kernels** (Roychowdhury/Pederson DAC'91) — ltra rms ~2e-3 with Bergeron cascade; exact match needs Bessel-kernel recursive convolution
- **PSP 103** verification vectors — vacask/mul wrong, vacask/c6288 hangs
- anything CMC ships that ngspice lacks (ASM-HEMT, MVSG) — future device coverage

| Source | What | Link |
|---|---|---|
| ngspice source | Exact numerics, every SPICE device (`src/spicelib/devices/`) | https://github.com/ngspice/ngspice |
| ngspice manual | Param semantics, levels, defaults | https://ngspice.sourceforge.io/docs/ngspice-manual.pdf |
| BSIM group Berkeley | Official BSIM3v3/BSIM4/BSIM-SOI/CMG/BULK manuals + code | https://bsim.berkeley.edu/models/ |
| CMC (Si2) | Industry-standard Verilog-A source: PSP, HICUM, Mextram, ASM-HEMT, MVSG | https://si2.org/standard-models/ |
| HICUM TU Dresden | HICUM/L0, L2 docs + VA | https://www.iee.et.tu-dresden.de/iee/eb/hic_new/hic_intro.html |
| VBIC | Spec, papers, reference code | https://designers-guide.org/vbic/ |
| Mextram (Auburn) | Definition doc + VA | https://www.eng.auburn.edu/~niuguof/mextram/ |
| EKV EPFL | EKV 2.6/3.0 model doc | https://www.epfl.ch/labs/iclab/ekv/ |
| PSP (CEA-Leti) | PSP 103 spec + VA | https://www.cea.fr/cea-tech/leti/pspsupport |
| Massobrio & Antognetti | *Semiconductor Device Modeling with SPICE* — classic equations in math form | ISBN 0-07-002469-3 |

Best combo per device: CMC/Berkeley PDF (intent) + ngspice `*ld.c`/`*temp.c` (bit-exact).

### Verilog-A source datasets (real production VA — loadable via our `.hdl` pipeline)

Coverage claim: **OpenVAF integration_tests + ngspice C source = full device coverage.**
Advanced models come as VA (below); classic builtins (mos1/2/3/6/9, jfet1/2,
mesa/hfet, GP BJT, switches, tline/LTRA/TXL/CPL, URC) have no official VA
anywhere — ngspice C stays their reference.

| dataset | models | link |
|---|---|---|
| OpenVAF integration_tests | BSIM3/4/6, BSIMBULK, BSIMCMG, BSIMIMG, BSIMSOI, PSP102/103, HICUM/L2, HiSIM2/HV/SOTB, MEXTRAM, EKV, ASMHEMT, MVSG, DIODE_CMC + primitives | https://github.com/pascalkuthe/OpenVAF/tree/master/integration_tests |
| CMC releases (si2) | Same models, canonical/latest versions | https://si2.org/standard-models/ |
| Berkeley BSIM | BSIM-BULK/CMG/IMG/SOI latest VA (click-through) | https://bsim.berkeley.edu/models/ |
| designers-guide | VBIC VA (not in OpenVAF set) | https://designers-guide.org/vbic/ |
| VACASK repo | OSDI-consumed VA models it ships/tests with | https://codeberg.org/arpadbuermen/VACASK |

Shortest path to open wants: load PSP103 + BSIMSOI VA directly through `.hdl`
instead of hand-porting — gated on FastVAF swallowing production VA
($param_given, analog functions, noise decls); see FastVAF coverage matrix.

## 2. Analysis

**Looking for:** Spectre-class and beyond. Spectre = Kundert's algorithms,
nearly all published. Target checklist to beat:
1. TR-BDF2 / strict LTE control + errpreset-style tolerance bundles (maps to our modular accuracy/perf knobs)
2. Robust OP homotopy chain: gmin → source → pseudo-transient
3. Krylov-shooting PSS + pnoise (SpectreRF core)
4. Multirate/envelope for RF (MPDE) — kills the "million cycles" problem Spectre brute-forces
5. Parallel/GPU transient — Spectre X's edge; our megakernel angle

### Spectre's actual algorithms (public)
| Source | What | Link |
|---|---|---|
| designers-guide.org | Kundert's papers: transient tolerances/LTE, PSS shooting, pnoise, HB, envelope — effectively the Spectre spec | https://designers-guide.org/analysis/ |
| Kundert/White/Sangiovanni-Vincentelli | *Steady-State Methods for Simulating Analog and RF Circuits* | https://link.springer.com/book/10.1007/978-1-4757-2081-5 |
| Telichevesky/Kundert/White DAC'95 | Matrix-free Krylov shooting (SpectreRF PSS) | https://dl.acm.org/doi/10.1145/217474.217574 |
| Kundert | *The Designer's Guide to SPICE and Spectre* — semantics, convergence rationale | ISBN 0-7923-9571-9 |
| Bank et al. 1985 | TR-BDF2 origin (L-stable, no trap ringing) | https://ieeexplore.ieee.org/document/1485943 |

### Past-Spectre (SOTA)
| Source | What | Link |
|---|---|---|
| Najm | *Circuit Simulation* — best modern textbook: convergence, homotopy, integration | https://onlinelibrary.wiley.com/doi/book/10.1002/9780470561218 |
| Roychowdhury | MPDE multirate (2-time PDE) | https://ieeexplore.ieee.org/document/917977 + https://people.eecs.berkeley.edu/~jr/ |
| MATEX DAC'14 | Matrix-exponential integrators — larger stable steps than BDF/trap | https://dl.acm.org/doi/10.1145/2593069.2593160 |
| Xyce math formulation | Open parallel theory doc: HB, sensitivity, PTRAN homotopy | https://xyce.sandia.gov/files/xyce/Xyce_Math_Formulation.pdf |
| Xyce publications | Sandia parallel/HB papers | https://xyce.sandia.gov/publications/ |
| VACASK | Direct benchmark target — docs spell out op ladder + integrator choices | https://codeberg.org/arpadbuermen/VACASK |
| Nagel SPICE2 thesis | Canonical MNA/LTE/convergence baseline (ERL-M520) | https://ptolemy.berkeley.edu/projects/embedded/pubs/downloads/spice/index.htm |

Priority read: designers-guide tolerance+shooting papers → Najm → Xyce math doc.

## 3. Solvers

**Looking for:** anything past KLU-class for circuit matrices (our direct.zig
already does BTF+AMD+Gilbert-Peierls+refactor). Wins left: parallel/GPU
factorization, better refactor heuristics, non-AD eval paths feeding assembly
(profiling shows device eval ≈50% of runtime on big linear circuits, solver ~13%).

| Source | What | Link |
|---|---|---|
| KLU paper | "Algorithm 907: KLU" Davis & Palamadai Natarajan | https://dl.acm.org/doi/10.1145/1824801.1824814 |
| Palamadai Natarajan thesis | KLU algorithm walkthrough, readable | https://ufdcimages.uflib.ufl.edu/UF/E0/01/17/21/00001/palamadai_e.pdf (also mirrored in SuiteSparse `KLU/Doc/`) |
| SuiteSparse | KLU/AMD/BTF reference source | https://github.com/DrTimothyAldenDavis/SuiteSparse |
| Davis | *Direct Methods for Sparse Linear Systems* — Gilbert-Peierls theory | https://epubs.siam.org/doi/book/10.1137/1.9780898718881 |
| NICSLU | Parallel circuit LU (beats KLU multicore); EOL — successor CKTSO | https://github.com/chenxm1986/nicslu + https://github.com/chenxm1986/cktso |
| GLU (UCR) | GPU sparse LU for circuit simulation, code + papers (GLU3.0 repo renamed) | https://github.com/sheldonucr/GLU_public |
| Sparse 1.3 (Kundert) | Original SPICE3 sparse package | https://sparse.sourceforge.net/ |
| ngspice cktop.c | gmin/source stepping ladder, exact | https://github.com/ngspice/ngspice/blob/master/src/spicelib/analysis/cktop.c |
| Kelley & Keyes | Pseudo-transient continuation convergence theory | https://epubs.siam.org/doi/10.1137/S0036142996304796 |
