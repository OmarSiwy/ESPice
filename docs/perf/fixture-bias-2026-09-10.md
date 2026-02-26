# `sweep/opamp_wl_*` — re-biased out of the convergence gate

`docs/perf/mos1-ac-2026-09-10.md` proved that the 3.1968e+05 "error" on
`sweep/opamp_wl_{200,1000,5000}` is not a model discrepancy: `VBIAS = 0.55`
against `VTO = 0.7` holds every tail device in cutoff, so every branch current
in the deck sits at **1.368e-12 A against `abstol = 1e-12 A`** and the two
engines simply stop Newton at different points *inside* the tolerance. The
deck measured the convergence gate, not the circuit.

This is the fixture-side fix. **`VBIAS` goes 0.55 → 1.0** on all three decks;
nothing else changes, and no espice source changed. The original deck is kept
verbatim as `convergence/ota_cutoff_abstol`, labelled in its own header so its
number cannot be read as a model error again.

Everything below was re-taken on `fixture-bias` rebased onto `spice-audit`
ff4de56 (`.options tnom` plumbed, per-instantiation Jacobian width,
exact-lifetime allocator, noise kinds), against ngspice-44.2. The espice
binary is this worktree's own `zig-out/bin/espice`, built from this branch —
not the main tree's, which moved under the earlier half of this session.
Scratch dir `/tmp/fb2`.

## 1. The new bias and its margin over `abstol`

`VBIAS = 1.0` gives `M5` a gate overdrive of `1.0 − 0.7 = 0.3 V` over `VTO`.
Every MOSFET drain current in `opamp_wl_200`, from ngspice's own `.op`
(`show all : id` over all 1000 devices; `/tmp/fb2/op200_{old,new}.txt`):

| | `min \|Id\|` | median | max | `min / abstol` | devices ≤ 10·`abstol` |
|---|---:|---:|---:|---:|---:|
| before, `VBIAS = 0.55` | 1.7186e-13 | 1.6988e-12 | 3.1494e-10 | **0.17** | **852 / 1000** |
| after, `VBIAS = 1.0` | **2.1962e-07** | 4.8261e-06 | 1.4855e-05 | **2.196e+05** | **0 / 1000** |

The margin claim is therefore: **the weakest branch in the deck carries
2.20e-07 A, 2.2e5 × `abstol`**, and no device in the deck is within five
decades of the gate. Before, the *median* device was 1.7× `abstol` and 85 %
of the deck sat inside 10× it.

The floor is set by the weakest `W/L` instance — the weakest device is
`m4_10`, in `Instance 10: W=0.500u L=5.000u`, `W/L = 0.1` — whose input pair
cannot pass the tail current, so its `tail` node collapses and `M5` runs deep
in triode. That is a self-limiting, well-conditioned operating point, not a
gate artefact, and it is why the minimum barely moves with `VBIAS` above ~0.8
while the strong instances scale as `(VBIAS − VTO)²`.

The same floor holds on all three decks, which is what their headers claim —
all three sweep the same `W`/`L` endpoints, so the weakest instance is in each:

```
op1000_new.txt: devices=5000  min=2.1962e-07 median=4.8332e-06 max=1.4855e-05 within10x=0/5000
op5000_new.txt: devices=25000 min=2.1962e-07 median=4.8336e-06 max=1.4855e-05 within10x=0/25000
```

`VBIAS = 1.0` was chosen as a round 300 mV overdrive, not tuned to the error.
The result is not sensitive to the exact value — §2 records 0.9 and 1.2 too.

## 2. Errors against ngspice, before and after

`ngspice -b -r` vs `zig-out/bin/espice -b --backend cpu -r` on the same deck,
per-variable error normalized by `max(peak, ptp, 1)` of the ngspice column —
the `benchmark/src/runner.zig comparePlots` rule, extended to complex data
(`/tmp/fb2/cmp.py`). "before" is the pre-change deck recovered with
`git show ff4de56:benchmark/fixtures/sweep/opamp_wl_N/circuit.sp`. The
comparator is validated by reproducing `mos1-ac-2026-09-10.md` §4's published
numbers exactly (`3.1968e+05` max abs dev, `8.4522e-01` worst normalized max
on `opamp_wl_200`).

| fixture | signals | max abs dev before | worst norm max before | median rms before | max abs dev after | worst norm max after | median rms after |
|---|---:|---:|---:|---:|---:|---:|---:|
| `sweep/opamp_wl_200` | 608 | 3.1968e+05 | 8.4522e-01 | 1.5537e-01 | **4.3708e-06** | **6.1360e-09** | **8.8098e-16** |
| `sweep/opamp_wl_1000` | 3008 | 3.1968e+05 | 9.3417e-01 | 1.6431e-01 | **4.3708e-06** | **6.1361e-09** | **8.4192e-16** |
| `sweep/opamp_wl_5000` | 15008 | 3.1968e+05 | 9.3423e-01 | 1.6702e-01 | **4.3708e-06** | **6.1361e-09** | **8.3811e-16** |

Worst normalized max improves by **1.4e8×**; median rms by **1.8e14×**. The
worst residual signal in every deck is `v(d1_*)` of the highest-`W/L` instance
(`d1_191` / `d1_981` / `d1_4951`, all `W=50u L=0.1u` — the same physical
instance in each, since the three decks share sweep endpoints), at 6.1e-9
normalized. The pass gate is `max ≤ 1e-2` and `rms ≤ 1e-3`; the re-biased
decks clear it by six and twelve decades. **These numbers are now a
measurement of the MOS1 model.**

Robustness — the same comparison on `opamp_wl_200` at three candidate biases,
to show the fix is not tuned to `1.0`:

| `VBIAS` | max abs dev | worst norm max | worst norm rms | median rms |
|---:|---:|---:|---:|---:|
| 0.55 (before) | 3.1968e+05 | 8.4522e-01 | 7.9836e-01 | 1.5537e-01 |
| 0.90 | 9.6374e-04 | 1.0180e-06 | 6.0084e-07 | 9.5659e-16 |
| **1.00 (shipped)** | **4.3708e-06** | **6.1360e-09** | **3.4831e-09** | **8.8098e-16** |
| 1.20 | 1.4454e-03 | 2.7707e-06 | 1.5058e-06 | 8.2975e-16 |

Any bias that turns the tail device on recovers four to eight decades, and the
median signal is at the f64 floor at all three. `1.0` happens to be the best
of the three on the worst signal by a further two decades; that is where each
engine's Newton stops, not a property of the bias, and the claim in §1 is the
`2.2e5 × abstol` margin, not the 6.1e-9.

**Caveat, stated plainly:** `zig build bench` still prints `N/A` for all three
decks, because `comparePlots` returns `null` on any complex plot
(`benchmark/src/runner.zig:460`). So this improvement is **not** visible in
the harness table and these decks are still not gated. Making the harness
score complex plots would newly score six AC fixtures and is a separate,
deliberate change to what the suite gates on; it is not done here.

## 3. Structure is unchanged

Required, because the GPU and memory work is measured on these decks. The only
edited line per deck is `Vbias vbias 0 DC 0.55` → `Vbias vbias 0 DC 1.0`, plus
six comment lines in the header:

```
$ git diff --stat ff4de56 -- benchmark/fixtures/sweep/
 benchmark/fixtures/sweep/opamp_wl_1000/circuit.sp | 8 +++++++-
 benchmark/fixtures/sweep/opamp_wl_200/circuit.sp  | 8 +++++++-
 benchmark/fixtures/sweep/opamp_wl_5000/circuit.sp | 8 +++++++-
```

`opamp_wl_5000`, old deck vs new, from `ZP_LU_STATS=1`
(`/tmp/fb2/stats_{old,new}.txt`):

| | old | new |
|---|---|---|
| devices | 30004 | 30004 |
| DC unknowns `n` | 15009 | 15009 |
| DC `nnz` / `L` / `U` / fill | 115017 / 70006 / 105006 / 1.5x | 115017 / 70006 / 105006 / 1.5x |
| AC unknowns (split complex) | 30018 | 30018 |
| AC `nnz` / `L` / `U` / fill | 460068 / 305037 / 445037 / 1.6x | 460068 / 305037 / 445037 / 1.6x |
| AC points | 91 | 91 |

Instance counts, topology, `W`/`L` sweep, node count and matrix fill are
bit-identical. Nothing recorded against these decks' *size* needs revisiting.

## 4. Peak RSS re-measure on `opamp_wl_5000`

`time -v` — the same instrument as `runner.zig measurePeakRss`, which shells
out to GNU `time -v` and parses `Maximum resident set size`. Three runs of each
deck, `espice -b --backend cpu -r`:

| deck | run 1 | run 2 | run 3 | median MB |
|---|---:|---:|---:|---:|
| old (`VBIAS = 0.55`) | 143064 kB | 142392 kB | 142588 kB | **139.24** |
| new (`VBIAS = 1.0`) | 142828 kB | 142336 kB | 143036 kB | **139.48** |

**RSS did not move.** The 0.24 MB gap is 0.17 %, inside each deck's own
run-to-run spread (0.47 % old, 0.49 % new). `ZP_MEM_STATS=1` confirms it row
by row — every label is identical to the 0.01 MB except `parse: source + AST`
(691 → 692 B/device, the six extra header comment lines) and the run arena's
*requested* total (45.13 → 45.25 MB, same 38.87 MB live and peak):

```
old  [mem] TOTAL tracked 112.87 MB   VmHWM 139.13 MB
new  [mem] TOTAL tracked 112.99 MB   VmHWM 139.77 MB
```

`docs/perf/memory-2026-09-10.md`'s `260.6 → 138.7 MB` row for this deck stands
as written and **needs no note from this branch**: 139.48 vs its 138.7 is
+0.6 %, and the *old* deck measures 139.24 at the same tip, so whatever drift
there is came from landings between that doc and `ff4de56`, not from the
re-bias. Node count and fill are unchanged (§3), so the per-device and
per-unknown constants derived from this deck are unaffected either way.

### What did move: the DC phase's wall clock

An OTA that is actually on takes more Newton iterations than one entirely in
cutoff. `opamp_wl_5000`, best of five runs each:

| | old | new | change |
|---|---:|---:|---:|
| espice, full deck (`.ac dec 10 1 1G`) | 0.58 s | 0.93 s | +60 % |
| espice, `.op` only | 0.17 s | 0.55 s | +224 % |
| ngspice, full deck | 4.12 s | 4.05 s | −2 % (noise) |

The whole espice delta is in the DC solve; the 91-point AC phase is unchanged
(same `n`, same `nnz`, same point count). ngspice does **not** move — its
runtime on this deck is dominated by the AC phase, so the extra Newton
iterations vanish into it. The espice-vs-ngspice ratio therefore moves
7.1× → 4.4×. Any *timing* number recorded against `opamp_wl_5000` —
`docs/perf/gpu-layout-2026-09-10.md`, `pareval-2026-09-10.md`,
`baseline-446268a.md`, `RESULTS.md` — shifts by this much and should be
re-baselined at the next full `zig build bench`. The GPU-relevant portion (the
batched AC solve) does not move.

## 5. The (a)/(b) call: keep the near-`abstol` deck, separately and loudly

**Taken: (b).** The original deck is preserved verbatim as
`benchmark/fixtures/convergence/ota_cutoff_abstol/circuit.sp`.

Reasoning. The near-`abstol` bias is genuinely worth testing — it is a real
convergence-gate stress case, it is the only deck in the corpus where the
entire signal lives at the tolerance floor (§6 confirms this across all 290
fixtures), and it found a subtlety neither engine's documentation mentions
(ngspice's device gate at `mos1conv.c:79-81` is a 73 % gate on a device whose
whole drain current is 1.368e-12 A). Deleting that coverage to fix a labelling
problem is the wrong trade. (a) would have been right only if the deck taught
nothing; it teaches something no other fixture does.

But (b) is only correct if the label is impossible to miss, because the failure
mode is a *reader*, not a runner: the trap that burned an agent-hour in a
previous session was reading `3.1968e+05` out of a results table as a model
discrepancy. A doc note does not reach that reader. So the label lives in three
places the reader actually passes through:

1. **The deck's own header** — a 26-line banner whose first line is
   `* 5T OTA at the abstol floor -- CONVERGENCE-GATE STRESS, NOT AN ACCURACY
   REFERENCE`, stating the number, why it is not a model error, and what the
   deck *is* for (`.../ota_cutoff_abstol/circuit.sp:1-26`).
2. **The deck's title card.** That first line is also the SPICE title, so both
   engines copy it into the raw header: `Title: * 5t ota at the abstol floor
   -- convergence-gate stress, not an accuracy reference`. Anyone who opens
   the raw, or any comparator that prints the plot title, sees it without
   opening the netlist.
3. **The re-biased decks' headers**, which point back at it, so a reader who
   wonders why `VBIAS` is 1.0 finds the history rather than "improving" it.

Scoring: it needs none. Its analysis is `.ac`, so `comparePlots` already
returns `N/A` for it (`runner.zig:460`), exactly as it did for the three
`opamp_wl_*` decks — the deck is present, timed and RSS-measured, but not
compared. Adding a per-fixture exclusion would have been a change to the pass
rule and is not needed.

Verified verbatim. The netlist bodies are identical — `diff` of both files
with comment lines stripped is empty — and both engines produce byte-identical
raw *payloads* on the new deck and the pre-change `opamp_wl_200`; only the
ASCII title line differs:

```
espice  payload identical: True  (886712 bytes)
ngspice payload identical: True  (886712 bytes)
ota_cutoff_abstol, ng vs espice: max abs dev 3.1968e+05, worst norm max
  8.4522e-01 (v(d1_181)), median rms 1.5537e-01   -- i.e. exactly the old row
```

So the convergence-gate coverage is preserved to the bit, and
`mos1-ac-2026-09-10.md`'s entire analysis still reproduces against a deck that
is in the tree.

## 6. Near-gate scan of the rest of the corpus

The general form of the bug: a deck whose *reported* result is a small-signal
expansion about an operating point sitting at the tolerance floor. Scan:
`/tmp/fb2/scan.sh` runs every `benchmark/fixtures/*/*/circuit.sp` — **290 of
the 290 `.sp` files in the corpus** — through ngspice with every analysis card
commented out and `.control op / show all : id ic ib is / .endc` in its place;
`/tmp/fb2/triage.py` classifies the result.

Two corrections to the naive version of this scan, both of which change the
answer:

- **Only the conducting terminal current counts.** Take `|id|` where ngspice
  printed one (MOS/JFET/MESFET/diode), else `|ic|` (BJT). `ib` and `is` are
  dropped: a MOSFET's bulk current is diode leakage at 1e-21 A *by
  construction*, so counting it makes every CMOS deck in the tree look like it
  sits at the gate — including the re-biased `opamp_wl_200`, whose weakest
  *drain* is 2.2e-07 A.
- **A gate-level OP is only a defect if the reported analysis linearizes about
  it** (`.ac .noise .tf .sp .pz .disto .stb .sens .dcmatch .op`). A `.dc`
  sweep's first point or a `.tran`'s `t=0` state at the floor is normal — the
  analysis drives the circuit off it.

For the analyses that matter the scan is exact, not approximate: a `.ac`/`.op`
deck's operating point *is* the sources at their DC card values, which is
precisely what the scan solves.

### Result

| class | count |
|---|---:|
| A. small-signal/`.op` reported **and the median device within 10× `abstol`** — the `opamp_wl` signature | **4** |
| B. small-signal/`.op` reported, some device within 10× `abstol` but not the median | 2 |
| C. gate-level device but `.dc`/`.tran`-driven — not a defect | 56 |

`sweep/opamp_wl_{200,1000,5000}` are in none of the three classes after the
re-bias; before it, `opamp_wl_200` and `opamp_wl_1000` were class A.

**Class A, all four examined individually:**

| fixture | min \|I\| | median \|I\| | verdict |
|---|---:|---:|---|
| `convergence/ota_cutoff_abstol` | 1.719e-13 | 1.699e-12 | the known one, deliberate and labelled (§5) |
| `devices/bsim3` | 5.599e-15 | 5.599e-15 | flagged, not poisoned |
| `devices/diode_capacitance` | 2.010e-12 | 2.010e-12 | flagged, not poisoned |
| `devices/hicum2` | 9.439e-12 | 9.439e-12 | flagged, not poisoned |

- `devices/diode_capacitance`: the whole DC current is ngspice's `gmin` × 2 V
  = 2e-12 A through a reverse-biased diode. But the reported quantity is
  `Cj(V)` via `i(vac)` over 1 kHz–1 GHz, where `|ωCj| ≈ 3.6e-8 S` against
  `gmin = 1e-12 S` — the capacitive admittance dominates the conductance by
  four decades, and `Cj` depends on the junction *voltage*, which an ideal
  source pins exactly. ng vs espice: **1.5613e-16** worst normalized max.
- `devices/bsim3`, `devices/hicum2`: both report only `.op`, and every node in
  both is pinned by an ideal source to within the IR drop of a sub-pA current
  (`5.6e-15 A × 10 kΩ = 5.6e-11 V`; `9.4e-12 A × 500 Ω = 4.7e-09 V`), so the
  reported voltages carry no gate-limited information at all. ng vs espice:
  **1.2336e-16** and **3.7122e-10** worst normalized max.

**Class B** — `convergence/diode_bridge` (4.186e-12) and `mosfet/nand2`
(5.010e-12) — is an off device inside an otherwise resolved deck: the normal,
intended state of half a logic gate or a bridge rectifier. ng vs espice:
**2.7450e-07** and **9.5850e-19**.

So: **no second instance of the defect.** All six flagged decks agree with
ngspice to 2.7e-07 or better, five of the six to 1e-15 or better — five and
thirteen decades inside the `1e-2` / `1e-3` pass gate. Runs in
`/tmp/fb2/g_*_{ng,zp}.raw`.

### A related finding that is *not* this bug

`devices/bsim3` and `devices/hicum2` both name themselves a bias-point fixture
and both sit with the device **off**: ngspice reports `vth = 1.95187` against
`vgs = 1` for the BSIM3 (`id = 5.6e-15 A`), and `ic = 9.44e-12 A` for the
HICUM/L2. They compare clean precisely because they measure nothing — the
node voltages are the rails. That is a coverage gap, not a tolerance-gate
defect, and fixing it changes what those fixtures measure, so it is left
alone and recorded here.

(Noted in passing: espice omits two of ngspice's five variables on
`devices/hicum2`; the comparator skips them. Unrelated to this branch.)

### Scan coverage, honestly

Of 290 fixtures: 117 printed a nonzero conducting current and are classified
above. 76 printed conducting currents that are all exactly zero — every one a
`.dc` or `.tran` deck whose sources sit at 0 V once the sweep card is
commented out, i.e. class C by construction. 76 have no semiconductor device
at all. 21 ngspice could not run; each is accounted for:

- 6 ngspice **cannot run at all**, unmodified, on this install
  (`devices/b3soi{dd,fd}`, `devices/vdmos`,
  `verilogA/{diode_clamp,res_divider}`, `verilog/inverter` — the last three
  are Verilog-A/HDL). They have no ngspice reference in the suite either, so
  there is no engine-vs-engine number for a gate-level OP to poison.
- 3 are passive-only (`topology/voltage_loop`, `ngspice/res_{array,partition}`
  — zero lines matching `^[MQDJZ]`); no semiconductor branch exists.
- 12 report only `.dc`, `.tran` or a `golden/` analysis: class C regardless.

`noise/bjt_flicker` landed with `ff4de56` after the batch scan and was scanned
on its own: `ic = 1.81552e-03 A`, 1.8e9 × `abstol`. Not near the gate.

## 7. Reproducing

```sh
zig build                       # this worktree, fixture-bias on spice-audit ff4de56
ESP=$PWD/zig-out/bin/espice

# the three re-biased decks vs ngspice, before and after (§2)
for n in 200 1000 5000; do
  git show ff4de56:benchmark/fixtures/sweep/opamp_wl_$n/circuit.sp > /tmp/fb2/old_$n.sp
  for v in old:/tmp/fb2/old_$n.sp new:benchmark/fixtures/sweep/opamp_wl_$n/circuit.sp; do
    tag=${v%%:*}; d=${v#*:}
    ngspice -b -r /tmp/fb2/${tag}_ng_$n.raw $d
    $ESP -b --backend cpu -r /tmp/fb2/${tag}_zp_$n.raw $d
    python3 /tmp/fb2/cmp.py /tmp/fb2/${tag}_ng_$n.raw /tmp/fb2/${tag}_zp_$n.raw   # needs numpy
  done
done

# the branch-current margin (§1)
sed -E 's/^[[:space:]]*\.(ac|op)\b/*&/I; s/^[[:space:]]*\.end$/.control\nop\nshow all : id\n.endc\n.end/I' \
  benchmark/fixtures/sweep/opamp_wl_200/circuit.sp > /tmp/fb2/op200_new.sp
ngspice -b /tmp/fb2/op200_new.sp > /tmp/fb2/op200_new.txt
python3 /tmp/fb2/opstats.py /tmp/fb2/op200_new.txt

# RSS (§4) and the structure table (§3)
time -v $ESP -b --backend cpu -r /tmp/fb2/rss.raw \
  benchmark/fixtures/sweep/opamp_wl_5000/circuit.sp
ZP_MEM_STATS=1 ZP_LU_STATS=1 $ESP -b --backend cpu -r /tmp/fb2/o.raw \
  benchmark/fixtures/sweep/opamp_wl_5000/circuit.sp

# the corpus near-gate scan (§6)
/tmp/fb2/scan.sh && python3 /tmp/fb2/triage.py
```

No espice source file changed; `src/` is untouched on this branch.
`zig build test`: **409/409** at this commit, the same count as `spice-audit`
ff4de56 itself.
