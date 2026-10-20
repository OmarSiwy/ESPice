# Examples

## MATCHA-style sizing sweep: ESPice vs HSPICE

`bench/matcha/` holds one FPGA-tile sizing template in plain HSPICE syntax. It runs the way
MATCHA runs ESPice: thousands of small `.tran` + `.meas` points on one circuit, each point with
its own fins and its own wire parasitics. The same file runs unchanged in HSPICE and in ESPice, so
the two can be compared point by point.

| File | What it is |
|---|---|
| `gen_mux_sweep.py N [SEED]` | writes the deck with N sizing points (deterministic for a seed) |
| `mux_sweep_16.sp` | 16 points, seed 1: quick comparison |
| `mux_sweep_4096.sp` | 4096 points, seed 1: throughput run (the GPU lane size, E1) |
| `compare_hspice.py` | lines up HSPICE's `.mt0` against ESPice's per-point `.meas` blocks |

### The circuit

asap7 TT, BSIM-CMG LEVEL 72 (`7nm_TT.pm`, `nmos_rvt`/`pmos_rvt`), 0.7 V, 27 °C:

```
in ─▶ driver inv (nfd) ─▶ 2:1 transmission-gate mux (nft, input a selected)
   ─▶ wire π: cw ─ rw ─ cw ─▶ buffer inv (nfb1) ─▶ buffer inv (nfb2) ─▶ out ── cl
```

- **Per point** (one `.data` row each): `nfd`, `nft`, `nfb1`, `nfb2` (fins), `rw` (wire R),
  `cw` (wire C per π half), `cl` (load). These are drawn uniformly by the generator; MATCHA
  feeds them as live parameters in the same layout.
- **Stimulus**: `in` rises at 50 ps and falls at 550 ps (20 ps edges), with a 1.2 ns transient on a
  1 ps step. Every point has identical edge times, so all points share one time grid, which is
  what lane batching needs.
- **Measures** (`out` is inverted from `in`):
  - `tpd_hl`, `tpd_lh`: 50 % delays.
  - `trise`, `tfall`: 20–80 % slews.
  - `e_cycle`: supply energy over one full cycle, `integ par('-vdd*i(vdd)')`.

### Setup

Both simulators read `.include '7nm_TT.pm'` from the deck's directory. Link your PDK copy there:

```sh
cd bench/matcha
ln -s <asap7>/root/models/hspice/7nm_TT.pm 7nm_TT.pm   # this machine: ~/Documents/University/ECE636/MiniProj1/.schemify/pdks/asap7/58d72c9d…/root/models/hspice/7nm_TT.pm
```

Regenerate decks of any size with `./gen_mux_sweep.py 1024 7 > mux_sweep_1024.sp`.

### Run HSPICE

```sh
hspice -i mux_sweep_16.sp -o mux_sweep_16      # writes mux_sweep_16.mt0, one row per .data point
```

### Run ESPice

ESPice picks its defaults itself, so no flags are needed:
- **Dialect:** detected from the deck (`.data` and `sweep data=` mark it as HSPICE; a note on
  stderr says so).
- **Jobs:** `--jobs` is the CPU count.
- **MATCHA mode:** with no `-r` output nothing reads the waveforms, so `.meas` streams, each point
  stops once its measures resolve, and operating points start from the nominal one. The printed
  values are the same as a full run.

The deck sets `.temp 27` explicitly, because the HSPICE dialect otherwise runs at TNOM 25 °C.

```sh
espice mux_sweep_16.sp > espice_16.txt            # everything automatic

espice -r out.raw mux_sweep_16.sp > espice_16.txt # also write waveforms: auto streaming turns off
espice --full-waveforms mux_sweep_16.sp           # keep waveforms in memory without writing them
espice --jobs=1 mux_sweep_16.sp                   # serial; output bytes are identical at any --jobs
espice --lanes mux_sweep_16.sp                    # CPU lane batching (off by default: break-even on CPU); same output
```

### Compare

```sh
./compare_hspice.py mux_sweep_16.mt0 espice_16.txt 1e-2
```

It prints every point/measure beyond the tolerance and the worst relative difference per measure.
Points are matched by `.data` row order. For reference, the asap7 inverter/NAND2 check
(Analog-Skills `espice.md`) found ESPice within 1e-5 of ngspice-OSDI on delays at equal
temperature, so differences much above ~1e-3 here point at a model or option difference, not
noise. Likely sources: `.option` defaults (HSPICE's RELTOL/ABSTOL/METHOD), TNOM, and HSPICE's
own BSIM-CMG version against ESPice's built-in 112.1.0.

### GPU lanes

The GPU lane backend (#208) runs each sweep point as one GPU thread: thread order is
lane-innermost, so 32 points of one transistor share a warp. Experiment E1
(`dev/research/gpu-lane-e1.md`) measured the bsimcmg kernel at 0.066–0.081 of one CPU core on an
RTX 4060. That makes the 4060 about 1.4–2x the whole 24-core CPU; A100 and H100 are projected
(not measured) at 4–26x and 7–69x the 4060. It ships in v1.2.0 (phases 3–6, plans in
`dev/research/plans/`):

```sh
espice --backend cuda mux_sweep_4096.sp > espice_4096_gpu.txt
./compare_hspice.py mux_sweep_4096.mt0 espice_4096_gpu.txt 1e-2
```

- `--backend cuda` (or `hip`) turns GPU lanes on. `auto` uses them only on FP64-class GPUs
  (A100/H100); on a consumer card such as the 4060 it stays on the CPU.
- The first GPU run per model compiles its kernels in the driver (bsimcmg about a minute) and caches them.
- Fill the GPU: it wants thousands of points per batch (E1 measured at N = 1024–4096; ~16k
  points saturate an 8 GB card).

Measured with ESPice v1.2.0 Debug on `mux_sweep_16.sp`: all 16 points resolve (no NaN). For
example, point 0 has `tpd_hl` 37.7 ps, `tpd_lh` 40.7 ps, `trise` 11.5 ps, `tfall` 9.7 ps and
`e_cycle` 2.11 fJ. The plain, MATCHA-mode and `--lanes` runs print identical measures.
