# ESPice against HSPICE: analyses, control cards, and a build order

HSPICE is Synopsys's SPICE. HSPICE RF, documented alongside it, adds
harmonic balance, shooting Newton, envelope and phase-noise analyses. This
page lists every HSPICE analysis and control card. For each one it says
whether ESPice or VACASK has it, what users get from it, how it would fit
ESPice's architecture, and roughly how much code it takes. It ends with a
build order. The VACASK side comes from
[vacask-comparison.md](vacask-comparison.md), and the build order folds in
that page's gaps (the fuller `acstb`, `dcxf`/`acxf` and multi-tone HB) so
the two lists do not compete.

Scope and sources:

- ESPice: `main` at `febfa18`. Paths are relative to the repository root.
- HSPICE: the E-2010.12 manual set, cross-checked against B-2008.09 and
  Z-2007.03 copies and the K-2015.06 Quick Reference. Citations use these
  keys (URLs under [Sources](#sources)):
  - **[CR]** *HSPICE Reference Manual: Commands and Control Options*.
    Chapter 2 has one section per command, cited as `[CR .LSTB]`.
    Chapter 3 covers options.
  - **[SA]** *HSPICE User Guide: Simulation and Analysis*, cited by
    chapter.
  - **[RF]** *HSPICE User Guide: RF Analysis*.
  - **[SI]** *HSPICE Signal Integrity User Guide* (A-2007.12).
  - **[QR]** *HSPICE Quick Reference* (K-2015.06).

  I found no command reference newer than K-2015.06 that I could read, so
  cards added after mid-2015 are missing here.
- Behaviour marked "observed" comes from probe decks (§1) run with
  `--tokenizer=hspice` on an ESPice binary built from `2dee4bf`, which
  differs from `febfa18` only in `src/device` (PULSE breakpoints).
- Sizes are the ones [vacask-comparison.md](vacask-comparison.md) uses:
  S is under 300 lines of Zig, M is 300 to 1,000, L is over 1,000.

## 1. Silent failures

A deck that runs and prints a wrong answer is worse than one that fails to
parse, so these come before any missing analysis. Every row below produces
output with no error. Rows marked "observed" come from running the deck;
the others come from reading the code.

| # | HSPICE input | What HSPICE does | What ESPice does | Fix | Size |
|---|---|---|---|---|---|
| S1 | `.GLOBAL vdd`, then a subcircuit that uses `vdd` without a port | every `vdd` at any level is one net [CR .GLOBAL] | ignores the card; the subcircuit gets its own `x1.vdd` (observed: a divider reads `v(out) = 0` instead of 0.5 V) | a global-name set filled in walk 1; `netOf` (`netlist.zig:988`) checks it before prefixing | S |
| S2 | `.ALTER` block | reruns the deck with the block's cards replacing same-name cards [SA Ch.4 "Altering Design Variables and Subcircuits"] | ignores the card and reads the block into the base deck (observed: `r1 a 0 1k` plus an altered `r1 a 0 2k` gave `i(v1) = -1.5 mA`, both resistors in parallel) | reject until C1 lands | S |
| S3 | `.TEMP -55 25 125` | runs every analysis at each of the three temperatures [CR .TEMP, Example 1] | reads start/stop/step: one DC point at -55 °C, and `.op` runs at 27 °C (observed); every other analysis also runs at 27 °C, per `analyses.zig` | list semantics in the HSPICE dialect, with every query fanned out per temperature (A5) | S |
| S4 | `.TRAN 0.1n 10n 1n 40n` | two segments: 0.1 ns steps to 10 ns, then 1 ns steps to 40 ns. The fields are read as tstart/delmax only when tstep2 < tstop1 and tstop2 < tstop1 [CR .TRAN] | ngspice reading: stops at 10 ns and suppresses output before 1 ns (observed) | HSPICE's double-point rule in the HSPICE dialect | S |
| S5 | no `.OPTION TNOM`, no `.TEMP` | TNOM defaults to 25 °C and the circuit runs at TNOM [SA Ch.20 "Simulating Circuit and Model Temperatures"] | 27 °C for both, whatever the dialect (observed: a 1 mA diode reads 0.6551 V; the ideal-diode value at 25 °C is 0.6508 V) | 25 °C defaults in the HSPICE dialect | S |
| S6 | `.param rv=agauss(1k,100,3)` and `r1 a 0 rv` | nominal value, 1 kΩ, outside a Monte Carlo run [SA Ch.20 "Monte Carlo Parameter Distribution"] | a 1 mΩ resistor (observed: `i(v1) = -1000 A` at 1 V). The same happens with `gauss`, `unif`, `aunif`, `limit` and an undefined name. The inline `r=agauss(...)` form fails with `UnresolvedParameter` instead. My unverified guess: the unfolded name is being read as a model name | error on a `.param` that does not fold; fold distributions to their nominal outside Monte Carlo | S |
| S7 | `E1 b 0 LAPLACE a 0 1 / 1 1e-3`, `G1 b 0 VCR a 0 1m`, `E1 b 0 DELAY a 0 TD=1n` | Laplace transfer, voltage-controlled resistor, ideal delay [SA Ch.31 "Behavioral Modeling"] | the keyword becomes a node name (`v(laplace)`, `v(vcr)`, `v(delay)`) and the output reads 0 (observed). `POLE`, `FREQ`, `OPAMP`, `VCCAP`, `NPWL`/`PPWL` and `TRANSFORMER` probably go the same way; not run | reject the keywords (A1), then implement (E1) | S |
| S8 | `.CONNECT b c` | nets b and c are one net [CR .CONNECT] | ignored (observed: `v(c) = 0` while `v(b) = 1`) | top-level alias in `netOf` | S |
| S9 | `.NODESET`, `.DCVOLT`, `.LOAD` | OP initial guess; initial conditions (same as `.IC`); a saved OP [CR] | ignored (`netlist.zig:779`, `card orelse return`) | `.dcvolt` is an `.ic` alias; `.nodeset` is vacask-comparison G3; `.load` is C6 | S each |
| S10 | `.LSTB`, `.LIN`, `.NET`, `.FFT`, `.STIM`, `.SAMPLE`, `.ACMATCH`, `.DCSENS`, `.TRANNOISE` in its HSPICE form, the HB/SN/ENV family, `.MOSRA`, `.BIASCHK`, `.POWER` | an analysis or report | no output and no message (observed for `.lstb`, `.lin`, `.net`, `.fft`: the run printed only the `.ac` plot) | A1 turns each into an error that names the card | S |
| S11 | `.OPTION GSHUNT=1e-3 CSHUNT= GMINDC= DELMAX= RUNLVL=6 ACCURATE ABSV= RELV= SEARCH=` | these change the solution or where libraries are found [CR Ch.3] | options outside the 13 names in `analyses.zig:75-81` (plus `scale`, read in `netlist.zig:1211`) are skipped without a message (observed for GSHUNT: the answer did not move) | A9 maps the ones that change answers; the rest get one warning listing them. Landed: GSHUNT, CSHUNT, GMINDC, DELMAX, ABSV/RELV/ABSI, RUNLVL/ACCURATE/FAST (as `trtol`), SEARCH | S |
| S12 | `W1 in 0 out 0 RLGCMODEL=m N=1 L=0.1`, `S1 ... MNAME=`, `U1 ...`, `B1 ... file= model=`, `P1 in 0 port=1` | lossy line, S-parameter block, lossy line, IBIS buffer, port [SA Ch.8; SI] | letters kept their ngspice meaning in every dialect: W was a current switch, S a voltage switch, U a URC line, B a behavioural source, P a CPL line | W and S are built in the HSPICE dialect (E2, E3, [w-s-elements.md](../devices/w-s-elements.md)); U and B are still rejected there | done for W/S |

Some HSPICE forms fail loudly, but the error names neither the card nor
the line. Each of these gives only `InvalidAnalysisArguments` or
`ParseError` (observed): `.NOISE v(b) v1 5`, `.PZ v(b) v1`, `.DISTO r2`,
`.OP 1n`, `.DC v1 LIN 3 0 1`, `.DC <param> ...`, any `SWEEP`, a `.DATA`
block, a `.VARIATION` block, `E1 ... POLY(1) ...` and `E1 ... VOL='...'`.

`.MEASURE` forms outside ngspice's set are dropped with a
`warning: netlist: ignoring malformed card` line (observed). That covers
an omitted analysis type (HSPICE then uses the last analysis requested
[CR .MEASURE (FIND and WHEN)]), `INTEGRAL`, `DERIVATIVE`, `PARAM=` and
`ERR1`. The run then finishes with the measurement missing.

The probe decks, each ending in `.end`:

```spice
* S1                      * S2                    * S3
.global vdd               v1 a 0 1                d1 a 0 dmod
vdd vdd 0 1               r1 a 0 1k               i1 0 a 1m
.subckt load a            .op                     .model dmod d is=1e-14
r1 a vdd 1k               .alter                  .temp -55 25 125
.ends                     r1 a 0 2k               .op
x1 out load
r2 out 0 1k               * S6                    * S7
.op                       .param rv=agauss(1k,100,3)   v1 a 0 1
                          v1 a 0 1                     e1 b 0 laplace a 0 1 / 1 1e-3
                          r1 a 0 rv                    r2 b 0 1k
                          .op                          .op
```

## 2. The HSPICE set, card by card

Columns: what the card does, where ESPice stands (with the path when it has
something), whether VACASK has it, the value to users, and the size of the
gap. Sketches for anything larger than a frontend alias are in §3, keyed by
the build-order id in the last column.

### 2.1 Core analyses

| Card | What it does | ESPice | VACASK | Value | Build id, size |
|---|---|---|---|---|---|
| `.OP [fmt] [t1 t2 ...]` | OP report; with times, OP snapshots during `.TRAN` written as `.ic0` [CR .OP] | `.op`, no time points (`dc/op.zig`) | `op` | time points: medium | B2, S |
| `.DC var start stop incr [var2 ...]`, `LIN/DEC/OCT/POI`, `START=/STOP=/STEP=`, `SWEEP`, `DATA=`, `MONTE=`, `OPTIMIZE=` [CR .DC] | DC sweep, nested, over sources, element and model parameters, `.PARAM` names, TEMP | two levels, linear step, over V/I/R/C/L/TEMP (`dc/dc.zig`) | `sweep` over anything, any depth | high | B3 (grids, S), C1 (params, DATA), C3 (MONTE) |
| `.AC type np f1 f2 [SWEEP ...]`, `POI`, `DATA=` [CR .AC] | small signal; also hosts `.NOISE`, `.DISTO`, `.LIN`, `.LSTB`, `.ACMATCH`, `.SAMPLE` | DEC/OCT/LIN, SIMD frequency lanes (`ac/freq.zig`) | `ac` | POI: low; SWEEP: high | B3, C1 |
| `.TRAN tstep1 tstop1 [tstep2 tstop2 ...] [START=] [UIC] [SWEEP ...]` [CR .TRAN] | transient, multi-segment, swept | ngspice form (`tran/tran.zig`); segments misread (S4) | `tran` | high | A6 (S), C1 |
| `.NOISE ov src [inter] [listckt listfreq listcount listfloor listsources]` [CR .NOISE] | noise over the `.AC` sweep, sorted per-device table, per-subcircuit sums | ngspice form with its own sweep; totals only (`ac/noise.zig`) | `noise` with `n(inst)` and `n(inst,contrib)` | high | B1, S |
| `.DISTO Rload [inter [skw2 [refpwr spwf]]]` [CR .DISTO] | HD2, HD3, SIM2, DIM2, DIM3 into a load | ngspice form: HD2/HD3, and with `f2overf1` the f1+f2, f1-f2, 2f1-f2 vectors (`post/disto.zig`) | no | low to medium | B6 done (ngspice form) |
| `.TF ov src` [CR .TF] | DC gain, Rin, Rout | yes (`dc/tf.zig`); every source at once as `.dcxf`/`.acxf` (`dc/xf.zig`, `ac/xf.zig`), V cards an F/H senses left out | `dcxf` (every source at once, plus `zin`/`yin`), `acxf` | medium | done |
| `.SENS ov ...` [CR .SENS] | DC sensitivity to every parameter | yes, adjoint (`sweep/sens.zig`) | no | medium | done |
| `.DCSENS outvar [Perturbation= Threshold= GroupByDevice=]` [CR .DCSENS; SA Ch.25] | finite-difference sensitivity to variation-block parameters | no | no | medium | C5, S after C3 |
| `.PZ ov src` [CR .PZ; SA Ch.15] | poles and zeros | ngspice form (`eigen/pz.zig`) | no | medium | B2, S |
| `.FOUR f ov1 [ov2 ...]` [CR .FOUR] | DC plus 9 harmonics and THD over the last period | one output (`post/four.zig`) | no | medium | B2, S |
| `.FFT ov [START STOP NP FORMAT WINDOW ALFA FREQ FMIN FMAX]` [CR .FFT; SA Ch.14] | windowed FFT of a transient, 8 windows, THD at FREQ | no; silently ignored | no | high for data converters and PLLs | B5, M |
| `.LIN [sparcalc noisecalc gdcalc mixedmode2port format dataformat ...]` [CR .LIN; SA Ch.17] | S/Y/Z/H, mixed-mode S, group delay, stability factors, 2-port and N-port noise parameters; writes `.sc#`, Touchstone 1/2, CITI | S/Y/Z/H, mixed-mode S, group delay, K and MU, two-port noise; Touchstone 1.0, or 2.0 when port impedances differ (`ac/sp.zig`) | `acsp` (S) | high for RF | C4, landed |
| `.NET` (obsolete, App.A) | Z/Y/H/S of a 1- or 2-port inside `.AC` | yes, ideal V/I ports, S against RIN/ROUT (`ac/sp.zig`) | no | low | C4, landed |
| `.LSTB mode=single\|diff\|comm vsource=v[,v]` [CR .LSTB] | loop gain by Middlebrook injection; GM, PM, unity-gain frequency and low-frequency gain in the listing | `.lstb` (`ac/lstb.zig`): Tian double injection as VACASK's `acstb`, single/diff/comm, `localgnd`, margins plot refined on the circuit, `.measure lstb`; `.stb` stays single injection | `acstb`: current and voltage injection, both directions, DUT y-parameters | high | done |
| `.SAMPLE FS= [TOL NUMF MAXFLD BETA]` [CR .SAMPLE] | noise folded by a sampler | `onoise_sampled` on every `.noise` spectrum (`ac/noise.zig`); BETA is a BETA/FS averaging window, ESPice's unconfirmed reading; TOL, NUMF checked and unused | no | low to medium | done |
| `.ACMATCH outvar ...` [CR .ACMATCH; SA Ch.23] | AC mismatch per device from the variation block | no | no | medium | C5, M |
| `.DCMATCH outvar ...` [CR .DCMATCH; SA Ch.23] | DC mismatch per device | Pelgrom from W·L, not from a variation block (`dc/dcmatch.zig`) | no | medium | C5, S |
| `.TEMP t1 [t2 ...]` [CR .TEMP] | every analysis at each temperature | three-number sweep, DC OP only (`sweep/temp_sweep.zig`); S3 | `sweep option="temp"` | high | A5, S |
| `.TRANNOISE out METHOD=MC\|SDE SAMPLES= SEED= FMIN FMAX SCALE` [CR .TRANNOISE; RF Ch.9] | transient noise, sampled or SDE | white and flicker, BE (`tran/tran_noise.zig`): MC with SAMPLES (a plot per index, index 1 noiseless), SDE as exact covariance propagation of the same steps (dense, sources at the OP), TIME= landing; ESPice's own `.trannoise tstep tstop` too | white and flicker | medium | done |
| `.JITTER TRANNOISE\|TRAN TRIG ov VAL= TD=` [CR .JITTER] | time-interval-error jitter from transient noise | no | no | medium | C7 |
| (VACASK) `dcinc` | DC small-signal response to the sources' increments | `.dcinc` (`dc/xf.zig`) | yes | low | done |

### 2.2 RF analyses (HSPICE RF)

| Card | What it does | ESPice | VACASK | Value | Build id, size |
|---|---|---|---|---|---|
| `.HB TONES= NHARMS= INTMODMAX= SUBHARMS= SS_TONE= [SWEEP]` [CR .HB; RF Ch.5] | multi-tone harmonic balance | `.hb TONES= NHARMS= INTMODMAX=`, any number of tones, complex phasors per line, SUBHARMS, SS_TONE, SWEEP (`pss/mhb.zig`) | any number of tones, sparse blocks | high for RF | D2 done |
| `.HBAC sweep` [CR .HBAC; RF Ch.8] | periodic AC on the HB orbit | `.pac` on the shooting orbit (`pss/pac.zig`); multi-tone on the mixing products (`pss/mhb_lptv.zig`) | `hbac` | high for RF | D1, S after the orbit adapter |
| `.HBNOISE out src sweep [sidebands]` [CR .HBNOISE; RF Ch.8] | cyclostationary noise on the HB orbit | `.pnoise` on the shooting orbit (`pss/pnoise.zig`); multi-tone (`pss/mhb_lptv.zig`) | `hbnoise` | high for RF | D1, M (vacask-comparison G4) |
| `.HBXF out sweep` [CR .HBXF] | periodic transfer function | `.pxf` on the shooting orbit (`pss/pxf.zig`); multi-tone (`pss/mhb_lptv.zig`) | no | medium | D1, S |
| `.HBOSC`, `.SNOSC` [CR; RF Ch.7] | oscillator steady state, period solved | no (`.pss` is driven only) | `pss` autonomous | high for RF | D3, M |
| `.PHASENOISE out sweep method=0\|1\|2` [CR .PHASENOISE; RF Ch.7] | oscillator phase noise: nonlinear perturbation, periodic AC, broadband | METHOD=0 (white and flicker), 1, 2 and CARRIERINDEX on the autonomous HB orbit ([phase-noise.md](../analysis/phase-noise.md)); no listing, jitter or SPURIOUS | no | high for RF | D4 done |
| `.ACPHASENOISE out in carrier=` [CR .ACPHASENOISE] | phase-domain noise and jitter of a closed-loop PLL model | `.noise` over the `.ac` sweep read as L = S/2 dBc/Hz (factor unconfirmed); no jitter | no | low | D4 done |
| `.HBLIN sweep [NOISECALC=]` [CR .HBLIN; RF Ch.10] | frequency-translating S-parameters and noise figure (mixers) | S and SSB noise figure, single tone (`pss/hb_lptv.zig`) | no | medium | D5, landed |
| `.HBLSP NHARMS= FREQSWEEP POWERSWEEP` [CR .HBLSP; RF Ch.10] | large-signal, power-dependent S-parameters | no | no | medium | D5, M |
| `.SN TRES= PERIOD=` or `.SN TONE= NHARMS=` [CR .SN; RF Ch.6] | shooting-Newton PSS | `.pss` (`pss/pss.zig`) | `pss` | done | syntax alias, S |
| `.SNAC`, `.SNNOISE`, `.SNXF` [CR] | periodic AC, noise, transfer on the shooting orbit | `.pac`, `.pnoise`, `.pxf` | `pac` | done | syntax aliases, S |
| `.SNFT ov [FFT keywords]` [CR .SNFT] | FFT of the shooting result | no | no | medium | B5, S |
| `.PTDNOISE out TIME= sweep` [CR .PTDNOISE] | noise at a time point of the period, strobed jitter | `.ptdnoise` over `.sn` (`pss/pnoise.zig` `strobed`): one time or a LIN/DEC/OCT/POI TIME sweep, a plot per time; TIME=meas and `.MEASURE PTDNOISE` refused | no | medium | done |
| `.ENV`, `.ENVOSC`, `.ENVFFT` [CR; RF Ch.11] | HB envelope with time-varying phasors, oscillator start-up, FFT of the envelope | `.envelope` is sample-envelope following, a different method (`tran/envelope.zig`) | no | medium | D7, L |

### 2.3 Statistics, corners and optimization

| Feature | What it does | ESPice | VACASK | Value | Build id, size |
|---|---|---|---|---|---|
| `AGAUSS GAUSS AUNIF UNIF LIMIT` in `.PARAM` [CR .PARAM] | Monte Carlo distributions; nominal outside Monte Carlo | resolved only when multiplied by zero (`frontend/expr.zig`); S6 otherwise | `gauss agauss unif aunif` | very high: every PDK uses them | A2 (nominal, S), C3 |
| `SWEEP MONTE=val \| val firstrun=n \| list(...)` on `.DC/.AC/.TRAN` [CR .DC] | Monte Carlo around any analysis | all three forms, `list(a b:c)` included ([variants.md](../analysis/variants.md)) | `mc ... endmc` around any analysis | very high | C3, L |
| `.MODEL ... p=v DEV/n/dist=σ LOT/n/dist=σ` [CR .MODEL] | per-device and per-lot draws on model parameters | yes; a GAUSS value is 3 sigma [SA Ch.20], not checked against HSPICE ([variants.md](../analysis/variants.md)); AGAUSS/AUNIF and the blank-separated `dev/2 0.1` form are refused | no | high for older PDKs | C3 |
| `.VARIATION` with global, local, element and spatial blocks [CR .VARIATION; SA Ch.21-22] | Synopsys's variation block: random variables, per-parameter sigma, the source for MONTE, DCMATCH, ACMATCH and DCSENS | parse error | no | high for Synopsys-format PDKs | C3, part of L |
| `.OPTION SAMPLING_METHOD=SRS\|LHS\|Factorial\|OFAT\|Sobol\|Niederreiter`, `SEED`, `MODMONTE`, `MONTECON` [CR Ch.3] | sampling plans | seeded Gaussian only | LHS by default | medium | C3 |
| `.LIB 'f' corner` plus `.ALTER` with `.DEL LIB` [CR .LIB; SA Ch.4] | corners | `.lib` sections work (`frontend/source.zig`); no `.alter` (S2) | `alter` | very high | C1, M |
| `.DATA` inline, `MER`, `LAM` [CR .DATA] | table-driven sweeps | yes; `OUT=` refused ([variants.md](../analysis/variants.md)) | no | high for characterization | C1 |
| `.DESIGN_EXPLORATION` [CR; SA Ch.26] | design-space sweep block | no | no | low | E8, S after C1 |
| `.MODEL m OPT [METHOD=BISECTION\|PASSFAIL] ...`, `p=OPTxxx(init,lo,hi)`, `OPTIMIZE= RESULTS= MODEL=` [CR .MODEL; SA Ch.27] | Levenberg-Marquardt fitting of parameters to `.MEASURE GOAL=` targets; bisection and pass/fail searches | yes ([optimize.md](../analysis/optimize.md)): LM, bisection and pass/fail (METHOD or LEVEL 1-3), `GOAL <`/`GOAL >`, under `.step`; a bisection searches one parameter | no | medium to high for sizing and model fitting | C8, L |
| `.MEASURE ... pushout=` [CR .MEASURE (Pushout Bisection); SA Ch.19] | setup/hold search by bisection | no | no | medium for cell characterization | C8 |

### 2.4 Measurement and output

| Card | What it does | ESPice | VACASK | Value | Build id, size |
|---|---|---|---|---|---|
| `.MEASURE` TRIG/TARG, FIND/WHEN/AT, AVG/RMS/MIN/MAX/PP/INTEG, DERIV [CR .MEASURE] | scalar measurements | yes, ngspice spellings (`frontend/measure.zig`) | none built in (Python) | very high | done |
| `.MEASURE` without an analysis type, `INTEGRAL`, `DERIVATIVE`, `PARAM=`, `ERR/ERR1/ERR2/ERR3`, `GOAL/MINVAL/WEIGHT` | HSPICE spellings, arithmetic on measures, error functions for fitting [CR .MEASURE (Error Function); SA Ch.11] | dropped with a warning | none | high | A10, S |
| `DC_CONT/AC_CONT/TRAN_CONT`, `EM_AVG`, measures over NOISE, LSTB, FFT (THD, SNR, SNDR, ENOB, SFDR), PHASENOISE, PTDNOISE, DCMATCH, ACMATCH | every crossing; recovered electromigration current; measures over the newer analyses [CR index] | yes except NOISE. LSTB, PHASENOISE, PTDNOISE, DCMATCH and ACMATCH read their plots' columns by name: LSTB's margin keywords (`.meas lstb pm phase_margin`) and `lstb(db\|m\|p\|r\|i)` (phase in degrees), a bare `FIND col` on the one-row DCMATCH and margins plots. Our column names, not HSPICE's `DCm_*` variables; unconfirmed against HSPICE (`hspice/meas_lstb`, `meas_match`, `meas_ptdnoise`, `phasenoise/meas_phasenoise`) | no | medium | C9, M (NOISE left) |
| `.PRINT`, `.PROBE`, `par('expr')` outputs [CR .PRINT/.PROBE] | output selection and derived waveforms | ignored; ESPice writes every vector and honours ngspice `.save` | `save` | derived outputs: medium | A1 (ignore list), C9 |
| `.PLOT`, `.GRAPH`, `.WIDTH`, `.ACDCFACTOR` | obsolete (CR App.A) | ignored | no | none | accept and ignore |
| `.LPRINT (v1,v2) outs` [CR .LPRINT] | transient to VCD by logic thresholds | no | no | low | E4, S |
| `.DOUT`, `.VEC`, `.PAT` [CR; CR Ch.4] | expected digital outputs, digital vector stimulus files, bit-pattern sources | `.dout`, PAT sources with `.pat` names, and `.vec` inputs and outputs ([frontend.md](../frontend.md), unconfirmed against HSPICE); no bidirectional vectors | no | medium for mixed-signal | E4, M |
| `.STIM` [CR .STIM] | turns one run's outputs into PWL/DATA/VEC stimuli | transient PWL and DATA files ([frontend.md](../frontend.md), unconfirmed against HSPICE); AC, DC and VEC forms: no | no | low | E4, S |
| `.POWER`, `.POWERDC` [CR] | average/RMS/peak power per element or subcircuit; DC leakage per hierarchy | `.power`: AVG/RMS/MAX/MIN of a V source's absorbed power or any output variable ([frontend.md](../frontend.md), unconfirmed against HSPICE); `.powerdc`: no (no port currents) | no | medium | E5, M |
| `.BIASCHK` [CR .BIASCHK] | voltage, size and region violation monitor | expression form over the transient only ([frontend.md](../frontend.md)); element, region and size forms: no | no | medium for reliability sign-off | E5, M |
| `.CHECK SETUP/HOLD/SLEW/EDGE/RISE/FALL/IRDROP/GLOBAL_LEVEL` [CR] | timing and IR-drop checks | yes, violation counts per node ([frontend.md](../frontend.md), unconfirmed against HSPICE); no node wildcards | no | low to medium | E5, M |
| `.SURGE`, `.IVTH`, `.MODEL_INFO` [CR] | current-surge detection, constant-current Vth, parameter dump | no | no | low | E5, S each |

### 2.5 Control and netlist cards

| Card | What it does | ESPice | VACASK | Value | Build id, size |
|---|---|---|---|---|---|
| `.GLOBAL` [CR .GLOBAL] | global nets | ignored (S1) | global nodes | very high | A3, S |
| `.CONNECT n1 n2` [CR .CONNECT] | merge two nets | ignored (S8) | no | medium | A8, S |
| `.IC`, `.DCVOLT` [CR] | initial conditions | `.ic` yes; `.dcvolt` ignored | `ic=` | high | A8, S |
| `.NODESET` [CR] | OP initial guess | yes, ngspice semantics: seeds the guess and holds the nodes for one Newton, at the operating point and at every cold `.dc` point (`dc/nodeset_sweep_latch`) | yes | high | done |
| `.SAVE [TYPE=NODESET\|IC] [LEVEL=] [TIME=]`, `.LOAD [FILE=]` [CR] | write and reuse an OP | `.save` is read as ngspice vector selection | `store=`/`nodeset=` | medium | C6, S |
| `.STORE [time= repeat=]` [CR .STORE] | transient checkpoint and restart | no | no | medium for long runs | C6, M |
| `.ALTER`, `.DEL LIB` [CR; SA Ch.4] | rerun with edits | S2 | `alter` | very high | C1, M |
| `.DATA ... .ENDDATA` [CR .DATA] | tables | yes, inline and external | no | high | C1 |
| `.PARAM` expressions, UDFs `f(a,b)='...'`, `str()` [CR .PARAM] | parameters | reals, about 20 functions | 62 functions | medium | not ranked here |
| `.LIB`, `.INCLUDE`, `.HDL`, `.IF/.ELSEIF/.ELSE/.ENDIF`, `.SUBCKT` with parameters, `.PROTECT/.UNPROTECT` | library and hierarchy | yes (`frontend/source.zig`, `netlist.zig`); `.protect` is ignored, which is correct for simulation | yes | done | done |
| `.MACRO/.EOM`, `.ALIAS`, `.MALIAS`, `.SWEEPBLOCK`, `.TITLE` | synonyms, model aliases, sweep unions | no | no | low | A1 then S each |
| `.OPTION` set: `RUNLVL`, `ACCURATE`, `FAST`, `METHOD=TRAP\|GEAR\|BDF`, `RELTOL`, `ABSTOL`/`ABSI`, `VNTOL`/`ABSV`, `DELMAX`, `GMIN`, `GMINDC`, `GSHUNT`, `CSHUNT`, `ITL1/2/4`, `LVLTIM`, `DVDT`, `SEARCH`, `SCALE`, `TNOM`, `POST`, `PROBE`, `INGOLD`, `MEASOUT` ... [CR Ch.3] | tolerances, integration, output | 13 names mapped (`analyses.zig:75-81`) plus `scale`; `METHOD=BDF` errors; the rest silently ignored (S11). Done: `RUNLVL`, `ACCURATE` and `FAST` set `trtol` ([tolerance-system.md](../analysis/tolerance-system.md), unconfirmed against HSPICE); `SEARCH` adds include directories ([frontend.md](../frontend.md), fixture `hspice/search_lib.sp`) | its own option set | high | A9 (S), E7 (RUNLVL presets, M) |

### 2.6 Signal integrity and elements

| Element or card | What it does | ESPice | VACASK | Value | Build id, size |
|---|---|---|---|---|---|
| E/G behavioural forms: `VOL=`/`CUR=`, `POLY`, `LAPLACE`, `POLE`, `FREQ`, `VCR`, `VCCAP`, `DELAY`, `OPAMP`, `NPWL/PPWL`, `TRANSFORMER` [SA Ch.31-32] | behavioural and frequency-domain sources | plain linear E/G, B-sources (`models/bsource.va`); `POLY` and `VOL=` rejected; keyword forms misread (S7) | behavioural sources compiled to Verilog-A | high for analog behavioural decks | A1, then E1 (S to L per form) |
| W-element with `RLGCMODEL=`/`RLGCFILE=`/`UMODEL=`/`TABLEMODEL=` [SA Ch.8; SI] | multiconductor lossy line, frequency-dependent R and G | `RLGCMODEL=` and `RLGCFILE=`, N ≤ 4, Rs and Gd included, in every analysis: rational fit of each mode's Yc and delay-extracted propagation run by `models/wline_N.va` ([w-s-elements.md](../devices/w-s-elements.md)); `UMODEL`/`TABLEMODEL`/`FSMODEL`/`SMODEL` refused | ideal line only | high for SI | E2 done (RLGC) |
| U-element [SA Ch.8] | lumped lossy line | letter taken by URC | no | low | E2, S |
| S-element, Touchstone/CITI models [SA Ch.8; SI] | multiport S-parameter block, recursive convolution, passivity | Touchstone 1.0, up to 4 ports: passive vector fit run by `models/sparam_N.va` in every analysis ([w-s-elements.md](../devices/w-s-elements.md)); CITI, Touchstone 2.0, FQMODEL and mixed mode refused | no | high for SI | E3 done (Touchstone 1.0) |
| B-element, `.IBIS`, `.EBD`, `.PKG`, `.ICM` [SI] | IBIS buffers and packages | no | no | high for SI | E3, L |
| P-element [SA Ch.17] | port for `.LIN`, also a source | a V source behind a noiseless z0 resistor in every analysis; mixed-mode ports | port pairs | medium | C4, landed |
| `.STATEYE` [CR; SA Ch.18] | statistical eye and BER | no | no | medium for SerDes | E3, L |
| Field solver: `.MATERIAL`, `.LAYERSTACK`, `.SHAPE`, `.FSOPTIONS` | 2-D field solver for W-element models | no | no | low | out of scope |

### 2.7 Reliability

| Card | What it does | ESPice | VACASK | Value | Build id, size |
|---|---|---|---|---|---|
| `.MOSRA`, `.MODEL ... MOSRA`, `.APPENDMODEL`, `.MOSRAPRINT`, `.MOSRA_SUBCKT_PIN_VOLT` [CR; SA Ch.29] | HCI/BTI aging: integrate stress in a fresh run, extrapolate to `RelTotalTime`, rerun with degraded models | level 1 (ESPice's equations), SimMode 0 and 2, `.appendmodel`; `.mosraprint`, `.mosra_subckt_pin_volt` refused ([mosra.md](../analysis/mosra.md)) | no | medium for automotive and long-life designs | E6, landed |
| Electromigration | `.MEASURE ... EM_AVG` with `.OPTION EM_RECOVERY`; no separate analysis [CR .MEASURE; SA "Measuring Recovered Electromigration"] | no | no | low to medium | C9, S |

## 3. Implementation sketches

These follow the lane-axis doctrine and the data rules in `AGENTS.md`. A new
analysis touches the same places each time: a `cards` entry
(`frontend/netlist.zig:229`), a `Kind` and options struct
(`core/query.zig:389`), `buildJob` (`frontend/analyses.zig`), `schemaOf`
(`analysis/session.zig:522`), the executor dispatch
(`analysis/executor.zig:270`) and the C enum in `include/espice.h`, which
is checked at comptime. The sketches below skip that list.

### A1. Unknown-card policy

`readDirective` returns on any card missing from `cards`
(`netlist.zig:779`). That line is the source of S2, S8, S9 and S10.
Replace it with two maps:

- `ignored`: cards that only shape output or protection (`.probe`,
  `.print`, `.plot`, `.graph`, `.width`, `.protect`, `.unprotect`, `.prot`,
  `.unprot`, `.title`). ESPice writes every vector anyway.
- Everything else fails with `error.UnsupportedCard` after one
  `std.log.err` that names the card and the line. The `.meas` path already
  logs this way.

The HSPICE dialect also rejects the E/G keywords in S7 and the W/S/U/B/P
letters in S12 until they are implemented. `.option` names outside the map
get one warning that lists them. A11 is the same idea applied to
`InvalidAnalysisArguments`: log the card before returning. Each later item
then replaces an error with an implementation, never a silent drop with an
implementation.

### A2. Distribution functions and unfolded parameters

First find out why `r1 a 0 rv` with an unfolded `rv` becomes 1 mΩ (S6),
and fix it where every caller routes through. An unresolved parameter
must be an error, as the inline form already is. Then give
`expr.zig` a fold mode in which `agauss(nom, ...)`, `gauss`, `unif`,
`aunif` and `limit` return `nom`. Nominal mode is the default. C3 adds the
sampling mode.

### A3, A8. `.global` and `.connect`

`.global` names go into a set during walk 1 (declarations), since devices
are read in walk 2. `netOf` (`netlist.zig:988`) returns
`r.intern(node)` for a global name before it applies the path prefix.
`.connect n1 n2` at top level records `n2 → n1` in a small alias map that
`netOf` applies to top-level names. The manual forbids connecting nets in
different subcircuits [CR .CONNECT], so top level covers the common case;
subcircuit-scoped aliases can come later. `.dcvolt` is an `.ic` alias in
the card table.

### A5. `.temp` as a list, and every analysis at each temperature

In the HSPICE dialect, `.temp t1 t2 t3` is a list. The ngspice dialect keeps
ESPice's start/stop/step form, because the `temp/` fixtures use it. Each
query already runs on its own `Circuit` (`executor.zig`, "its own Circuit
instance"), so a temperature is one `setCircuitTemp` per query and needs no
re-preparation. `analyses.queries` copies every query once per temperature
and tags each copy's plot with it. Copies are independent, so `--jobs` runs
them concurrently, where HSPICE runs them one after another.

### A6, A7. `.tran` segments and HSPICE temperature defaults

`.tran` in the HSPICE dialect reads (tstep, tstop) pairs until a keyword
and applies [CR .TRAN]'s rule for the ambiguous double-point form. The run
stops at the last tstop, and each segment's tstep caps `dt_max` inside its
interval, which fits the existing breakpoint machinery. `DeckOptions`
defaults `tnom_c` to 25 in the HSPICE dialect, and circuit temperature
defaults to TNOM [SA Ch.20].

### A9. Options that change answers

`GSHUNT` and `CSHUNT` add a conductance and a capacitance from every node
to ground. That is one diagonal stamp per node row in the linear planes,
applied at build. `GMINDC` maps onto the gmin ESPice already has. `DELMAX`
sets `Tran.dt_max`. `ABSV`, `RELV` and `ABSI` alias `vntol`, `reltol` and
`abstol`. `SEARCH=` adds a directory list to `source.zig`'s path
resolution. `METHOD=BDF` maps to Gear. `RUNLVL`, `ACCURATE` and `FAST` are
E7: HSPICE does not publish their tolerance factors, so any mapping is a
recorded divergence with measurements, per the proof rule.

### A10, C9. `.MEASURE`

Add aliases to the `funcs` map in `measure.zig`: `integral` for `integ`,
`derivative` for `deriv`. An omitted analysis type takes the last analysis
card, which the caller knows. `PARAM='expr'` becomes a measure whose value
is an expression over earlier measure names, evaluated after the others in
card order. `ERR`, `ERR1`, `ERR2` and `ERR3` compare two vectors over the
sweep with the definitions in [SA Ch.11 "Error Equations"], including
`MINVAL`, `IGNOR`/`YMIN` and `YMAX`. `GOAL`, `MINVAL` and `WEIGHT` are
stored on the card and read by C8's optimizer. C9 adds the `_CONT` forms, `EM_AVG`
(max(I⁺avg, I⁻avg) − R·min(...), where R is `.OPTION EM_RECOVERY`), and
measures over the plots that B1, B4, B5 and C5 add.

### B1. HSPICE `.noise` and noise contributions

In the HSPICE dialect `.noise ov src [inter]` takes its frequencies from
the deck's `.ac` card, and it is an error if there is none. The
per-generator terms that `ac/noise.zig` forms before summing become
columns: one per device instance, plus one per generator name within the
instance. Per-subcircuit sums (`listckt=1`) group columns by the graph's
`subckt_instance`. This is vacask-comparison G5's S half. The columns come
from the adjoint solve already in each frequency lane.

### B2, B3. Syntax for existing analyses

- `.pz ov src`: inputs from the source's nodes, `vol` or `cur` from its
  type, output from `v(a[,b])` or `i(v)`.
- `.four` with several outputs: one query per output.
- `.op t1 t2 ...`: a transient query that records x and device state at
  those times and publishes one operating-point plot per time. These
  snapshots are also C6's `.ic0` source.
- `.dc` grids: `LIN`, `DEC`, `OCT`, `POI` and `START=/STOP=/STEP=` all turn
  into the point list that `dc/dc.zig` walks. `SWEEP` names the second
  level.
- The SN family (`.sn`, `.snac`, `.snnoise`, `.snxf`) becomes card aliases
  for `.pss`, `.pac`, `.pnoise` and `.pxf` with keyword arguments.

### B4. `.lstb` and a complete stability analysis

`stb.zig` injects 1 V on one probe branch. Three changes:

1. `mode=diff` and `mode=comm` take two probe sources and drive both branch
   rows in the same right-hand side, +1/−1 for differential and +1/+1 for
   common mode. The loop gain is the ratio of the differenced or summed
   returns.
2. HSPICE uses Middlebrook's injection [CR .LSTB], and VACASK's `acstb`
   adds current injection and both loop directions. Current injection is
   a second right-hand side on the same lane factorization
   (`FreqSolver.solveBatch` takes several), so it costs a solve, not a
   factorization. The Middlebrook/Tian combination is already derived in
   [stability.md](../analysis/stability.md).
3. Margins: a pass over the (f, T) rows finds the unity-gain and −180°
   crossings by log-frequency interpolation and publishes GM, PM, FU and
   low-frequency gain as a second plot, the way `.noise` publishes its
   integrated plot. `.measure lstb` then reads that plot.

### B5. `.fft`, `.snft`, `.envfft`

Resample the transient onto NP uniform points in [START, STOP] with the
interpolation `post/four.zig` uses, apply one of the eight windows, and run
a radix-2 FFT. NP is a power of two [CR .FFT], so radix-2 covers every legal
NP. Output magnitude in dB and phase per bin, plus THD when FREQ is given.
FFT measures (THD, SNR, SNDR, ENOB, SFDR) read the same bins. `.snft`
takes the PSS orbit as its input and `.envfft` the envelope.

### B6. `.disto` two-tone terms

HSPICE's `.DISTO Rload` reports into a load resistor and adds SIM2, DIM2
and DIM3, with F2 = skw2·F1. ngspice defines the same two-tone terms
(`cktdisto.c` with `f2overf1`), so they extend `post/disto.zig` the way
HD2/HD3 were built, and the ngspice oracle stays available.

### B7. All-source transfer functions

One adjoint solve at the output gives the transfer from every independent
source at once. At DC that is `dcxf`, at each frequency lane `acxf`. Input
impedance per source needs one more solve per source, batched as
right-hand sides on the same factorization. `.tf` stays as the one-source
view. `dcinc` is the forward solve with each source's increment.

### C1. Variant runner: `.alter`, `.data` and parameter sweeps

Status: landed; see [variants.md](../analysis/variants.md) for what was built and where it differs from this sketch.

`.alter` has to re-prepare the deck anyway: it swaps `.lib` sections,
replaces models and elements, and can add devices [SA Ch.4]. That makes
re-preparation the first thing to build:

- The frontend splits the expanded text at `.alter` lines into a base and
  blocks. Variant k is the base with the block's cards substituted: a card
  whose kind and name match replaces the base card, `.param` replaces by
  name, `.lib` and `.del lib` add and remove sections. HSPICE's manual text
  is ambiguous about whether edits carry into later blocks, so check that
  against an HSPICE run before relying on either reading.
- Each variant is its own Problem. The facade runs them and labels each
  plot with the `.alter` title. Variants are independent, so `--jobs` runs
  them concurrently. HSPICE needs `-mp` and forked processes for that.
- `.data` is read in walk 1 as a table: column names, then values in
  row-major order in the parse arena, with `MER` and `LAM` concatenating
  or laminating files. `DATA=d` and `SWEEP param ...` on `.dc`, `.ac` or
  `.tran` become variants with `.param` overrides. `SWEEP` over sources
  and elements goes to the existing `.dc` path when the inner analysis is
  DC.

Preparation measured 15 to 17 ms for the 10,000-resistor grid
([preparation-performance.md](../Problem/preparation-performance.md)), so a
100-point sweep pays a few seconds at most on such a deck. That is correct
and simple. C2 makes it fast.

### C2. Live parameters

Status: landed; see [variants.md](../analysis/variants.md) for what was built and where it differs from this sketch.

This is vacask-comparison G1: a table of the device parameters that depend
on swept names, rewritten through `ParamRef.set`, with no re-preparation.
Land it under C1's interface and measure it against C1 on a PDK deck. A
point that changes topology falls back to C1.

### C3. Monte Carlo

Status: landed; see [variants.md](../analysis/variants.md) for what was built and where it differs from this sketch.

- Draws: a counter-based generator keyed by (seed, sample, call site,
  instance path), so any sample can be recomputed alone, in any order, on
  any worker. HSPICE's `firstrun=` and `list(...)` then become index sets
  and cost nothing extra. SRS draws Normal/Uniform from the counter; LHS
  permutes one stratification per call site.
- Sites: `agauss`/`gauss`/`unif`/`aunif`/`limit` inside `.param` and
  subcircuit defaults. A call in a subcircuit default is one site per
  instance, as PDK mismatch requires. `DEV/n/dist=σ` on a model parameter
  is one site per instance; `LOT/n/dist=σ` is one per model. The
  `.variation` block's global and local sections follow the same split,
  and its element section applies to instance parameters.
- Execution: a DC inner analysis runs samples as structural lanes
  (`sweep/lanes.zig`); anything else runs them as C1/C2 variants.
- Output: one plot per sample, plus per-measure mean, sigma, min and max.
  The existing `.mc N variation` stays as the no-generator fallback.

### C4. `.lin`

Status: landed, mixed mode, K/MU and `.net` included; see
[s-parameters.md](../analysis/s-parameters.md) §5 for what was built and
where it differs from this sketch (group delay by a central difference).

`sp.zig` already builds the full S-matrix per frequency lane, with one
right-hand side per port. On top of that:

- Y, Z and H (two-port) follow from S by closed forms on a small dense
  complex matrix per frequency; ports rarely exceed eight. Mixed-mode S is
  a fixed change of basis for port pairs.
- Group delay is −d∠S₂₁/dω. The exact derivative comes from
  dx/dω = −(G + jωC)⁻¹(jC)x, which is one more solve per port on the
  existing lane factor. That avoids differencing neighbouring sweep
  points.
- Stability factors (K, μ) are closed forms on S.
- Noise parameters: collect the device generators with
  `collectNoiseSources`, then for each frequency run one adjoint solve per
  port as extra right-hand sides on the same factor. That gives the port
  noise-wave correlation matrix, C_ij = Σ_s S_s·y_i,s·conj(y_j,s). NFmin,
  Rn and Γopt follow for two ports; `noisecalc=2` publishes the whole
  matrix.
- Ports come from P-elements (`P1 n+ n- port=1 z0=50`) mapped to
  `core.query.Port`. Output uses the Touchstone and CITI writers ESPice
  already has. `.net` is an alias.

### C5. Mismatch and variation sensitivities

Status: landed; see [dcmatch.md](../analysis/dcmatch.md) §3-4. One table
over local and global groups instead of HSPICE's split tables.

`.acmatch` follows `dc/dcmatch.zig` per frequency lane: one adjoint
right-hand side per frequency gives λ(ω), and each parameter costs a
finite-difference re-evaluation of G and C at the operating point. The
parameter's effect on the operating point comes from the DC adjoint that
dcmatch already has. `.dcmatch` and `.acmatch` read sigmas from the
`.variation` block once C3 parses it, and fall back to Pelgrom W·L without
one. `.dcsens` is a finite-difference loop over the same parameter list.

### C6. Saved operating points and checkpoints

`.save` in the HSPICE dialect writes the OP (or the `.op t` snapshot) as
`.nodeset` or `.ic` cards to `<deck>.ic0`. `.load` includes such a file.
The ngspice meaning of `.save` stays in the ngspice dialect. `.store` is
separate: it serializes the transient state (solution history, step, device
states) and resumes from it, which is M because every device's state
vector has to round-trip.

### C7. Transient noise and jitter

Accept `.trannoise` with HSPICE's keywords. Add flicker noise
(vacask-comparison lists Voss-McCartney and Lorentzian SDE sums), and move
off backward Euler onto the transient integrator's method. Samples are
independent runs, so they run concurrently under `--jobs`. A possible
experiment: at a fixed step, samples share one sparsity pattern and nearly
one pivot sequence, so they could be `LaneLu` lanes. That is only worth
trying with a measured before/after, because the doctrine does not list
samples as a lane axis. `.jitter` is a measure over the sample set.

### C8. Optimization

Parameters `p = OPTxxx(init, lo, hi)` plus the measures that carry `GOAL=`.
Levenberg-Marquardt with a finite-difference Jacobian costs N+1 variant
runs per iteration (C1/C2), and those runs are independent, so `--jobs`
applies. Bisection and pass/fail (`METHOD=BISECTION|PASSFAIL`, `pushout=`)
are a 1-D root find over one parameter on one measure. HSPICE runs these
serially, as far as its manual describes.

Status: Levenberg-Marquardt, bisection and pass/fail landed, with
inequality goals and `.step`; see [optimize.md](../analysis/optimize.md).
`pushout=` and a bisection over several parameters are refused.

### D1 to D7. RF

Follow vacask-comparison G4. Phase A adds an orbit adapter (`hbOrbit`) and
splits `pnoise.sweep` into an orbit provider and `orbitSweep`. After that,
`.hbnoise`, `.hbac` and `.hbxf` are the existing `pnoise`, `pac` and `pxf`
paths fed with the HB orbit. Phase B (D2) is multi-tone HB with a sparse
block Jacobian and a block-diagonal preconditioner whose K+1 blocks
G₀ + jkω₀C₀ are `LaneLu` frequency lanes, and complex phasor output.

- D3, oscillators: add the period to the shooting unknowns with a phase
  condition (vacask-comparison, "Oscillator PSS").
- D4, `.phasenoise`: the perturbation projection vector is the adjoint
  Floquet eigenvector of the monodromy matrix `pss.zig` already forms. The
  phase-noise spectrum projects each noise source through it, and
  method 1 is D1's periodic AC.
- D5: `.hblin` is D1's conversion matrix read between sidebands at
  P-element ports. `.hblsp` sweeps port power (a C1 sweep) over D2.
  Status: `.hblin` landed with `noisecalc=1` (single tone; see
  [pac.md](../analysis/pac.md) §2). P elements now keep z0 in the HB
  circuit; `.hblsp` is not built.
- D6: `.ptdnoise` is the pnoise machinery with the output sampled at one
  phase of the period. `.sample` folds a `.noise` spectrum computed out to
  MAXFLD·FS into [0, FS/2].
- D7: HSPICE's envelope integrates the harmonic phasors in slow time.
  ESPice's `.envelope` follows sample envelopes, a different method, so
  keep both and document the difference.

### E1 to E8. Long tail

- E1, behavioural E/G:
  - `VOL=` and `CUR=` compile to the B-source tape (`bsource.zig`).
  - `VCR` and `VCCAP` are controlled R and C, S each.
  - `DELAY` reuses the ideal line.
  - `LAPLACE` and `POLE` run on VerA's `laplace_nd` and `laplace_zp`
    (state-space sections in transient); POLE's limits are in
    dev/frontend.md "Pole-zero sources".
  - `FREQ` tables need convolution in transient (L).
- E2 (done for RLGC): the W element fits each mode's characteristic
  admittance and its delay-extracted propagation (Rs·√f and Gd·f included)
  as rational sections and runs them by the method of characteristics in
  Verilog-A; see [w-s-elements.md](../devices/w-s-elements.md). Tabular
  models (TABLEMODEL, UMODEL, FSMODEL, SMODEL) remain.
- E3: the S element is done for Touchstone 1.0 up to four ports (passive
  vector fit, [w-s-elements.md](../devices/w-s-elements.md)). IBIS and
  `.stateye` are each large, self-contained projects; build them only when
  SI users show up.
- E4, E5: digital and report cards read the result tables after the run,
  with one exception: `.biaschk` region checks need device
  operating-point values, which are blocked on VerA the same way
  vacask-comparison G5 is.
- E6, MOSRA: landed; see [mosra.md](../analysis/mosra.md). A fresh
  transient integrates stress per device, extrapolated to each
  reliability time, and the degraded `delvto`/`mulu0` go back in as
  variant rows (C2) for the aged runs.

## 4. Build order

Silent failures come first, then HSPICE syntax for analyses ESPice already
runs, then high-value analyses, then RF, then the long tail. Within each
tier, the smaller item with more users goes first.

| Rank | Id | Item | Size |
|---:|---|---|---|
| 1 | A1 | Unknown cards, E/G keywords and HSPICE-only element letters become errors that name the line; output-only cards go on an ignore list; unknown options are listed in a warning | S |
| 2 | A2 | Unfolded `.param` errors instead of becoming 1 mΩ; distributions fold to nominal | S |
| 3 | A3 | `.global` | S |
| 4 | A5 | `.temp` list, every analysis per temperature | S |
| 5 | A6 | `.tran` multi-segment form | S |
| 6 | A7 | HSPICE dialect TNOM and TEMP default to 25 °C | S |
| 7 | A8 | `.connect`, `.dcvolt`, `.nodeset` | S |
| 8 | A9 | GSHUNT, CSHUNT, GMINDC, DELMAX, ABSV/RELV/ABSI, SEARCH, METHOD=BDF | S |
| 9 | A10 | `.meas`: omitted analysis type, INTEGRAL/DERIVATIVE, PARAM=, ERR1-3, GOAL/MINVAL/WEIGHT | S |
| 10 | A11 | Analysis-card errors name the card and line | S |
| 11 | B1 | HSPICE `.noise` over the `.ac` sweep; per-instance, per-generator and per-subcircuit contributions | S |
| 12 | B3 | `.dc`/`.ac` grids (LIN/DEC/OCT/POI, START=/STOP=/STEP=, SWEEP over sources and TEMP) | S |
| 13 | B2 | `.pz ov src`, `.op` time points, multi-output `.four`, SN card aliases | S |
| 14 | B4 | `.lstb` modes and margins, then `acstb` completeness (current injection, both directions) | M |
| 15 | B7 | `dcxf`/`acxf`/`dcinc` | S |
| 16 | B5 | `.fft`, FFT measures, `.snft` | M |
| 17 | C1 | Variant runner: `.alter`, `.del lib`, `.data`, parameter `SWEEP`/`DATA=` on `.dc`/`.ac`/`.tran` | M |
| 18 | C3 | Monte Carlo: MONTE= forms, distributions, DEV/LOT, `.variation`, SRS/LHS | L |
| 19 | C4 | `.lin` with P-elements, noise parameters, exact group delay; `.net` alias | M |
| 20 | C2 | Live parameter table under C1, measured against it | L |
| 21 | C5 | `.acmatch`, variation-block `.dcmatch`, `.dcsens` | M |
| 22 | C6 | `.save`/`.load` OP files; `.store` checkpoints | S, M |
| 23 | C9 | `_CONT` measures, EM_AVG, measures over new plots, `par()` outputs | M |
| 24 | D1 | HB orbit adapter, `.hbnoise`, `.hbac`, `.hbxf` (done: [periodic-noise.md](../analysis/periodic-noise.md)) | M |
| 25 | D3 | Oscillator PSS (`.snosc`, `.hbosc`) (done: [pss-shooting-harmonic-balance.md](../analysis/pss-shooting-harmonic-balance.md)) | M |
| 26 | D2 | Multi-tone sparse HB with lane preconditioner and phasors | L |
| 27 | D4 | `.phasenoise` (METHOD=0/1/2, flicker, CARRIERINDEX) and `.acphasenoise`: done, [phase-noise.md](../analysis/phase-noise.md) | M, M |
| 28 | C7 | HSPICE `.trannoise`, flicker noise, `.jitter` | M |
| 29 | C8 | Optimization (LM, bisection, pass/fail: done, [optimize.md](../analysis/optimize.md); pushout) | L |
| 30 | B6 | `.disto` SIM2/DIM2/DIM3 and the Rload form | M |
| 31 | D5 | `.hblin`, `.hblsp` | M each |
| 32 | D6 | `.ptdnoise`, `.sample` | M, S |
| 33 | E1 | Behavioural E/G forms | S to L per form |
| 34 | E2 | W-element with frequency-dependent losses (RLGC done: [w-s-elements.md](../devices/w-s-elements.md); tabular models remain) | M |
| 35 | E7 | RUNLVL/ACCURATE/FAST presets, with the divergence recorded | M |
| 36 | E4 | `.vec`, `.pat`, `.dout`, `.lprint`, `.stim` | M total |
| 37 | E5 | `.biaschk`, `.check`, `.power`, `.powerdc`, `.surge`, `.ivth`, `.model_info` | M total |
| 38 | D7 | HB envelope (`.env`, `.envosc`, `.envfft`) | L |
| 39 | E6 | MOSRA aging | L |
| 40 | E3 | S-element (Touchstone 1.0 done: [w-s-elements.md](../devices/w-s-elements.md)), IBIS, `.stateye` | L each |
| 41 | E8 | `.design_exploration` | S |

Out of scope: the obsolete `.plot`, `.graph`, `.width` and `.acdcfactor`
(accepted and ignored), `.cfl_prototype`, back-annotation (`BA_*`, DSPF,
SPEF), `.module` (3D-IC), and the field-solver cards.

## 5. Where ESPice can beat HSPICE

These claims are about architecture, not measurements. Each needs a
benchmark before anyone repeats it.

- Every frequency-swept item (`.noise` contributions, `.lstb`, `.lin` with
  noise parameters and exact group delay, `.acmatch`, `acxf`) adds
  right-hand sides to one `LaneLu` factorization per frequency batch.
- Independent runs (`.alter` variants, `.temp` copies, Monte Carlo
  samples, optimizer probes) run concurrently under `--jobs` in one
  process. HSPICE parallelizes `.alter` and DC Monte Carlo through `-mp`
  and forked processes [CR .ALTER].
- Counter-based Monte Carlo draws make any sample reproducible on its own
  and independent of execution order.
- DC samples and temperatures run as structural lanes, and GPU device
  evaluation applies to every transient-based item.

## Sources

- [CR] *HSPICE Reference Manual: Commands and Control Options*, E-2010.12.
  <https://www.ele.uri.edu/Courses/ele448/HspiceRef/hspice_cmdref.pdf>
  (identical copy:
  <https://nthuee.org/archive/AIC/106%E8%AC%9D%E5%BF%97%E6%88%90/Hspice/hspice_cmdref.pdf>).
  Sections cited: .ALTER, .CONNECT, .DATA, .DC, .DCVOLT, .FFT, .GLOBAL,
  .LIN, .LSTB, .MEASURE (FIND and WHEN; Error Function; Pushout
  Bisection), .NOISE, .OPTION RUNLVL, .OPTION TNOM, .PARAM, .TEMP, .TRAN,
  and Appendix A "Obsolete Commands and Options".
- [SA] *HSPICE User Guide: Simulation and Analysis*, E-2010.12.
  <https://www.ele.uri.edu/Courses/ele448/HspiceRef/hspice_sa.pdf>.
  Chapters cited: 4 ("Altering Design Variables and Subcircuits", "Using
  Multiple .ALTER Blocks"), 8, 11, 14, 15, 17, 18, 19, 20 ("Simulating
  Circuit and Model Temperatures", "Monte Carlo Parameter Distribution"),
  21-23, 25-27, 29, 31, 32.
- [RF] *HSPICE User Guide: RF Analysis*, E-2010.12.
  <https://www.ele.uri.edu/Courses/ele448/HspiceRef/hspice_rf.pdf>.
  Chapters 5-11.
- [SI] *HSPICE Signal Integrity User Guide*, A-2007.12.
  <https://ece.iisc.ac.in/~dipanjan/E8_262/hspice_si.pdf>.
- [QR] *HSPICE Quick Reference*, K-2015.06.
  <https://www.synopsys.com/content/dam/synopsys/verification/datasheets/hspice_quickref_Jun2015.pdf>.
- Cross-checks: B-2008.09 at
  <https://cseweb.ucsd.edu/classes/wi10/cse241a/assign/hspice_cmdref.pdf>,
  Z-2007.03 at <http://www.rudraj.it/hspice_cmdref.pdf>.
- VACASK: [vacask-comparison.md](vacask-comparison.md) and the source it
  cites.
