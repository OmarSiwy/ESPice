# Fixture coverage

`golden/<analysis>/circuit.sp` covers each of the 24 registered analysis IDs.
`python3 benchmark/check_fixtures.py` requires all 24 decks, the requested
plot type, complete nonempty binary samples, finite values, and successful
execution. A missing plot or a simulator skip fails the run. OP, DC, AC,
temperature, sensitivity, mismatch, and transfer-function divider fixtures
also check analytical values. Monte Carlo requires four distinct-index
trials with nonconstant output. Other cases
are explicitly reported as smoke coverage, not accuracy conformance.
STB currently must reject with `UnsupportedStabilityAnalysis`; this reports
`XFAIL`, makes the default gate fail, and never counts as accuracy coverage.
`--allow-unsupported` permits that verified rejection for capability tests.

Run the gate and its own regression checks:

```sh
python3 -m unittest discover -s benchmark -p 'test_*.py'
python3 benchmark/check_fixtures.py
python3 benchmark/check_fixtures.py --category layout --reference
zig build test-fixtures -- --category layout --reference
```

`layout/` contains synthetic parasitic networks, not extracted production
layouts. `mesh_op` exercises an 8×8 resistive mesh with ground capacitance
and known row-symmetric voltages. `coupled_ac` exercises 16 matched RC routes;
common-mode excitation cancels coupling capacitance and gives an exact
single-pole response. `fanout_tran` exercises 32 unequal RC loads coupled
to adjacent routes. The reference gate checks every ngspice signal,
including complex phase and branch current, against ESPice. Transient
samples are linearly interpolated onto the reference times; mismatched
time coverage fails. This is a waveform check, not an independent proof
of either integrator's local truncation error.
`metal_island_tran` preserves a grounded floating-metal capacitance reduced
from the actual StrongARM PEX and checks its voltage remains zero.
`capacitive_divider_tran` requires the ungrounded DC node to start at half
the input voltage and remain there as the input changes. This catches a
static residual solve accepting arbitrary zero voltage before transient OP.

Reference tolerance is pointwise `atol + rtol * abs(reference)`, with
`rtol=1e-3`, voltage `atol=1e-6`, current `atol=1e-12`, and noise
`atol=1e-30`. No one-volt normalization floor or RMS-only acceptance.
Nested sweeps with repeated axes are rejected; split them into separate
decks. Unsupported ngspice analyses fail when `--reference` is requested.

## SKY130 corpus

Generate actual SKY130 model decks using an installed PDK:

```sh
python3 benchmark/sky130_corpus.py --pdk "$PDK_ROOT/sky130A"
python3 benchmark/check_fixtures.py --fixtures zig-out/sky130-fixtures \
  --category sky130 --reference
zig build test-fixtures -- --fixtures zig-out/sky130-fixtures \
  --category sky130 --reference
zig-out/bin/bench-runner zig-out/bin/espice zig-out/sky130-fixtures \
  --filter sky130 --iters 5 --no-xyce --out /tmp/sky130-results.md
```

For a short first pass, add `--sizes 4 --corners tt` to generation: ten
decks. Default generation emits 150 decks:

| Circuit family | Sizes | Analyses |
|---|---|---|
| Inverter chain | 4, 64, 1024 stages | OP, DC, transient |
| Current-mirror array | 4, 64, 1024 outputs | OP, DC, AC |
| Differential-pair array | 4, 64, 1024 pairs | OP, DC, AC, noise |

Each size/family runs five process corners. PVT points are tt/1.8 V/27 C,
ss/1.62 V/125 C, ff/1.98 V/−40 C, sf/1.8 V/27 C, and fs/1.8 V/27 C;
this is a selected corner set, not the full process×voltage×temperature
Cartesian product. Device models are the PDK's `nfet_01v8` and
`pfet_01v8` subcircuits, with dimensions expressed in the wrapper's
micrometre convention. There is no level-1 substitute.
Synthetic `.save` lists every physical topology node and voltage-source
current; extraction wrappers explicitly save DUT ports and driving-source
currents. Backend-specific compact-model internal nodes are outside this
declared comparison. Noise saves both spectral and integrated noise
quantities; missing plots or input-referred results remain gate failures.

`PROVENANCE.json` records the resolved PDK path/revision, dimensions of
the corpus, PVT points, and synthetic RC assumptions. Model files remain
external; decks carry absolute library paths so relative model includes
resolve under the PDK. Regenerate after relocating the PDK. Local audit
PDK revision: `fa87f8f4bbcc7255b6f0c0fb506960f531ae2392`, SKY130A.

These families represent common circuit structures, not a verified
production workload distribution. Interconnect values (8 Ω wire,
4/5 fF ground, 0.5 fF coupling) are synthetic; no layout extractor or
process extraction rules generated them.

## Actual extracted layouts

`--layout-root` adds immutable extracted sources from an existing design
repository. Repeat it for multiple extraction directories:

```sh
python3 benchmark/sky130_corpus.py --pdk "$PDK_ROOT/sky130A" --sizes 4 --corners tt \
  --out zig-out/sky130-extracted-fixtures \
  --layout-root /path/to/MVM/output/layout \
  --layout-root /path/to/MVM/scripts/verify_output
zig build test-fixtures -- --fixtures zig-out/sky130-extracted-fixtures \
  --category sky130_extracted --reference
```

Each source receives OP/DC/AC/transient wrappers. The wrapper binds observed
port order, applies explicit supply/input stimuli and 5 fF output loads,
and includes the source unchanged. No floating internal nets are grounded,
no devices are deleted, and no model substitutions are made. Source SHA256,
extractor header, exposed ports, explicit R/C counts and quality issues
are recorded in `PROVENANCE.json`. A changed source or a known interface
defect fails the gate before simulation. `LAYOUT_PORTS` records the design
interfaces from MVM's component generators; it does not infer missing pins.

Local corpus contains nine sources across seven design families. Six
`output/layout` block extractions have missing design pins; the tapeout
wrapper exposes its expected interface. StrongARM's separate Magic PEX
exposes seven pins and 71 explicit capacitors. Its KLayout LVS `.cir`
uses primitive MOS cards requiring validated PDK binding, so it is retained
as a rejected case instead of silently rewritten. None of these records
asserts LVS correctness. Extracted topologies with complete interfaces still
need successful ngspice/ESPice comparisons before any accuracy claim.

Use `--backend cuda` or `--backend hip` in the gate to require that
backend; missing hardware must fail. Benchmark timings alone cannot
establish accuracy, and finite plots alone cannot establish parity.

Current GPU capability gap: `build.zig` excludes model sources ≥80 KiB
from kernel emission. SKY130's BSIM4 maps to `bsim4va.va` (440,289 bytes),
so its active-device evaluations remain on CPU. Offloading associated
passives does not establish GPU BSIM4 support or GPU parity for this corpus.
