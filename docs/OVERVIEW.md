# ARPice overview

SPICE-compatible circuit simulator in Zig with CPU (Newton + sparse LU) and
GPU (JFNK/GMRES megakernel) solve paths. Benchmarked for ngspice compliance —
see `benchmark/README.md` and `benchmark/TRIAGE.md`.

## Choosing CPU vs GPU

- **CPU** (default): fastest for small/medium circuits. GPU has a fixed
  ~230 ms kernel launch + upload cost, so anything under a few thousand
  unknowns finishes on CPU before the GPU even starts.
- **GPU** (`--gpu`): recommended for **post-layout extraction runs** —
  extracted netlists with tens of thousands of parasitic RC elements and
  MOSFETs are where the all-devices megakernel amortizes its launch cost and
  the batched JFNK solve wins. Also the better path for large ensemble/sweep
  workloads (many lanes solved in parallel).

Rule of thumb: pre-layout schematic → CPU; post-layout extracted → GPU.
