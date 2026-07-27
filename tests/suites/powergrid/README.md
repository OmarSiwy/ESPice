# powergrid suite

Linear power-delivery networks taken from real designs: the IBM power grid
benchmarks (Nassif, ASP-DAC 2008) and SRAM-PG (Shen, Liu and Yu,
arXiv:2404.05260). They contain only R, C, L, V and I elements, so they test
parsing, assembly, ordering, factorization and the timestep loop, with no
device evaluation involved. Most grids ship a reference solution.

```
tests/suites/powergrid/fetch.sh zig-out/suites/powergrid
POWERGRID_LARGE=1 tests/suites/powergrid/fetch.sh zig-out/suites/powergrid
```

The script leaves `DIR/<name>.sp` decks and, where the source ships one,
`DIR/<name>.solution`. Downloads are cached in `DIR/src` and checked against
the sha256 sums pinned in `fetch.sh`; a rerun skips any file that already
exists. Nothing is vendored.

## Sources and licences

| Set | Pinned source | Licence |
|---|---|---|
| IBM ibmpg1-8, ibmpg1t-6t | `https://web.ece.ucsb.edu/~lip/PGBenchmarks/ibmpg/` (Peng Li, UCSB; page last updated 2020-03-19). Mirror without a licence: github.com/thesukantadey/IBM_power_grid_benchmarks | None stated. The page says "All rights reserved", so fetch only. |
| SRAM-PG | github.com/ShenShan123/SRAM-PG at `62a95026696e8f669e9aab25dba574a9cd65b74d`, git-lfs objects via `media.githubusercontent.com` | Apache-2.0 |

The UCSB server publishes MD5SUMS.txt for the uncompressed DC files. The
sha256 sums in `fetch.sh` cover the compressed downloads; they were taken on
2026-10-05. The SRAM-PG sums are the git-lfs object ids.

## Deck changes

- IBM DC decks run as shipped (R, V, I and `.op`).
- IBM transient decks drop the SPICE2 `.opti` and `.width` cards and turn
  `.print tran` into `.save` of the same 20 probe nodes, so the raw file
  stays small. They also gain `.options method=gear`: under ngspice-45's
  default trapezoidal rule, ibmpg1t stalls at t = 0.23 ps as the timestep
  keeps shrinking (it had not moved after 10 minutes), and with Gear it
  finishes.
- SRAM-PG decks begin with a resistor card, which SPICE would read as the
  title line, so the script adds a title. It drops the HSPICE
  `.option INGOLD=2 probe` card and the 40,544 `.meas` cards (one per node),
  and gives each transient deck a `.save` of the 20 nodes its solution file
  records.

## Solutions

| Deck | Solution | Format |
|---|---|---|
| ibmpg1-6 | `ibmpgN.solution` | `node value` per line, 5 significant digits |
| ibmpg1t-6t | `ibmpgNt.solution` (from `.output`) | `Node: name` blocks of `time value` rows, 20 probes |
| `<design>_dc` | `<design>_dc.solution` (from `.sol.ic`) | FineSim `.nodeset` of every node |
| `<design>_trans` | `<design>_trans.solution` (from `.sol.pt0`) | FineSim table: `time` plus 20 node columns |
| ibmpg7, ibmpg8 | none | |

Spot checks: ngspice's `.op` on ibmpg1 and ibmpg2 matches the first three
solution nodes to every printed digit. SRAM-PG warns that its own solutions
"may not be the accurate ones".

## Decks

Node counts are distinct node names other than ground, counted from the
deck. ngspice times are wall clock for `ngspice -b -r` with `.options klu`
added (ngspice-45 from nixpkgs), measured once each on an otherwise quiet
32-thread machine on 2026-10-06. ngspice-45 defaults to SPARSE 1.3, and the
bench runner keeps that default unless it gets `--ngspice-klu`. Pass that
flag for this suite; SPARSE 1.3 times were not measured on a quiet machine.

### Default

| Deck | Nodes | Elements | ngspice (KLU) | Peak RSS |
|---|---:|---:|---:|---:|
| ibmpg1 (DC) | 30,635 | 55,109 | 0.3 s | 0.1 GB |
| ibmpg2 (DC) | 127,235 | 246,581 | 2.9 s | 0.4 GB |
| ibmpg3 (DC) | 851,581 | 1,603,581 | 291 s | 3.9 GB |
| ibmpg1t (tran 10 ns) | 39,680 | 76,934 | 194 s (1,429 steps) | 0.1 GB |
| ssram_dc | 76,384 | 148,164 | 0.7 s | 0.2 GB |
| ssram_trans (tran 40 ns) | 76,384 | 185,670 | 588 s (4,044 steps) | 0.3 GB |

ssram_trans is close to the 10-minute line. Expect it to be the slowest deck
in the default set.

### Opt-in (`POWERGRID_LARGE=1`)

| Deck | Nodes | Why it is opt-in |
|---|---:|---|
| ibmpg4 (DC) | 953,580 | not measured: stopped after 3 minutes at 3.9 GB |
| ibmpg5 (DC) | 1,079,307 | not measured |
| ibmpg6 (DC) | 1,670,491 | not measured; 167 MB deck, expected to approach 8 GB |
| ibmpg7 (DC) | 1,461,038 | not measured; 149 MB deck, no solution |
| ibmpg8 (DC) | 1,461,038 | not measured; 157 MB deck, no solution |
| ibmpg2t | 164,237 | reached 0.94 ps of 10 ns in 15 minutes (timed out) |
| ibmpg3t-6t | 1,041,534 to 2,367,182 | larger than ibmpg2t |
| ultra8T, sandwich, sp8192w (DC and tran) | 4.5M to 5.9M (upstream counts) | 0.7 to 1.7 GB per deck, about 800 MB to download |

ibmpg7 and ibmpg8 are the two 1.46M-node grids on the UCSB page. Their size
matches what later papers call ibmpgnew1 and ibmpgnew2, but the page itself
never uses that name.

## Known limits of the bench runner

`tests/benchmark/ngspice.zig` reads decks up to 128 MiB (`1 << 27`) and
`vacask.zig` up to 64 MiB (`1 << 26`). Larger decks fail as `DeckFailed` in
those columns. In the default set that affects ibmpg3 (92 MB) under VACASK.
With `POWERGRID_LARGE=1` it also affects ngspice on ibmpg6-8, ibmpg3t-6t and
every large SRAM-PG deck.
