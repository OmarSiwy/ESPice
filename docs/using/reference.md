# Language reference

Every element letter and every dot card ESPice reads, in the ngspice
dialect unless a row says otherwise. The lists come from the parser's
tables: the card keyword map and the element letter map. A card not listed
here is refused with `UnsupportedCard`, naming the line.

Notation: `n+ n-` are nodes, `[x]` is optional, `...` repeats, and
`key=value` pairs may come in any order. Keywords are case-insensitive in
the ngspice and HSPICE dialects.

## Deck structure

```text
Title line (always the first line)
* comment
element cards
.control cards
.end
```

Logical lines: a line starting with `+` continues the one before it.
Comments: `*` at the start of a line; `$` or `;` cuts the rest of a line
(ngspice dialect). The [dialects](dialects.md) page has the HSPICE and
Spectre rules.

Values: a number with an optional scale suffix (`t g meg k m mil u n p f`,
any case; `m` is milli), a parameter name, `{expression}` or
`'expression'`.

Nodes: any word or number; `0`, `gnd` and `ground` are ground. Names inside
a subcircuit instance are prefixed with the instance path (`x1.n3`).

## Elements

The first letter of an element's name selects its kind.

| Letter | Element | Syntax |
|---|---|---|
| `R` | resistor | `R1 n+ n- value [tc1= tc2= m=]` |
| `C` | capacitor | `C1 n+ n- value [ic=v m=]` |
| `L` | inductor | `L1 n+ n- value [ic=i m=]` |
| `K` | mutual inductance | `K1 L1 L2 k` |
| `V` | voltage source | `V1 n+ n- [DC v] [AC mag [phase]] [waveform] [portnum n z0 Z]` |
| `I` | current source | `I1 n+ n- [DC i] [AC mag [phase]] [waveform]` |
| `E` | voltage-controlled voltage source | `E1 o+ o- c+ c- gain`, or a nonlinear form |
| `G` | voltage-controlled current source | `G1 o+ o- c+ c- gm`, or a nonlinear form |
| `F` | current-controlled current source | `F1 o+ o- Vsense gain` |
| `H` | current-controlled voltage source | `H1 o+ o- Vsense r` |
| `B` | behavioural source | `B1 n+ n- V={expr}`, `I={expr}` or `Q={expr}` |
| `S` | voltage-controlled switch | `S1 n+ n- c+ c- model` (`.model m SW(VT= VH= RON= ROFF=)`) |
| `W` | current-controlled switch | `W1 n+ n- Vsense model` (`.model m CSW(IT= IH= RON= ROFF=)`) |
| `T` | lossless transmission line | `T1 a1 b1 a2 b2 Z0= TD=` or `Z0= F= [NL=]` |
| `O` | lossy transmission line (LTRA) | `O1 a1 b1 a2 b2 model` (`.model m LTRA(R= L= G= C= LEN=)`) |
| `Y` | lossy transmission line (TXL) | `Y1 a1 b1 a2 b2 model` (`.model m TXL(R= L= G= C= LENGTH=)`) |
| `P` | coupled lines (CPL), 2 to 4 conductors | `P1 in1..inN ref1 out1..outN ref2 model` (`.model m CPL(...)`) |
| `U` | uniform distributed RC line | `U1 n1 n2 n3 model [L=len] [N=lumps]` (`.model m URC(K= FMAX= RPERL= CPERL=)`) |
| `D` | diode | `D1 anode cathode model [area] [m=]` |
| `Q` | bipolar transistor | `Q1 c b e [s] model [area]` |
| `M` | MOSFET | `M1 d g s b model [W= L= AD= AS= PD= PS= NF= m=]` |
| `J` | JFET | `J1 d g s model [area]` |
| `Z` | MESFET, MESA, HFET | `Z1 d g s model [area]` |
| `X` | subcircuit instance | `X1 n1 n2 ... subname [param=value ...]` |
| `N` | Verilog-A module instance | `N1 n1 n2 ... module [param=value ...]` (see [Verilog-A](devices.md#your-own-verilog-a)) |

In the HSPICE dialect `P` is a port, `S` an S-parameter block and `W` a
W-element line; `B` and `U` are refused. See the table below.

### Sources

Waveforms for `V` and `I` cards, in `.tran` (and as the drive in `.pss`,
`.hb` and the other periodic analyses):

| Waveform | Arguments |
|---|---|
| `PULSE(v1 v2 [td tr tf pw per [phase]])` | `tr`, `tf` default to the `.tran` step; `pw`, `per` to its stop time |
| `SIN(vo va [freq td theta phase])` | `theta` is the damping factor in 1/s; phase in degrees |
| `EXP(v1 v2 [td1 tau1 td2 tau2])` | |
| `PWL(t1 v1 t2 v2 ...) [r=t] [td=t]` | any number of points; `r=` repeats from time `t` (64 points at most with `r=`) |
| `SFFM(vo va [fm mdi fc td phasem phasec])` | ngspice order; HSPICE dialect reads `(vo va fc mdi fs)` |
| `AM(va vo mf fc [td phasec phases])` | |
| `PAT(vhi vlo td tr tf tsample data)` | HSPICE bit patterns (`b0101`, `[...]` groups, `R=`/`RB=` repeats), rewritten to PWL |

`DISTOF1 mag [phase]` and `DISTOF2 mag [phase]` on a V card mark the
`.disto` drive tones. `portnum n z0 Z` makes the source an S-parameter
port for `.sp` (HSPICE: a `P` card, `port=n z0=Z`).

### Controlled sources

The linear forms are in the table above. E and G (and where noted F and H)
also take these forms, named by the word in the first control-node slot:

| Form | Example |
|---|---|
| `VALUE={expr}` (also `VOL=`, `CUR=` in HSPICE) | `E1 out 0 VALUE={v(a)*v(b)}` |
| `POLY(n) c1+ c1- ... p0 p1 ...` (F, H: `POLY(n) V1 ... p0 p1 ...`) | `E1 out 0 POLY(2) a 0 b 0 0 1 1` |
| `TABLE {expr} = (x1,y1) (x2,y2) ...` | `G1 out 0 TABLE {v(in)} = (0,0) (1,1m)` |
| `PWL(1) c+ c- x1,y1 x2,y2 ... [DELTA=]` | `E1 out 0 PWL(1) in 0 0,0 1,5` |
| `LAPLACE c+ c- num... / den...` | `E1 out 0 LAPLACE in 0 1 / 1 1e-3` |
| `POLE c+ c- a az1,fz1 ... / b ap1,fp1 ...` | poles and zeros, roots s = −α + j2πf |
| `DELAY c+ c- TD=t` | `E1 out 0 DELAY in 0 TD=1n` |
| `VCR`, `VCCAP` (HSPICE) | voltage-controlled resistor and capacitor |
| `VCVS`, `VCCS`, `CCVS`, `CCCS` | the type word repeats the letter and is dropped |

Modifiers after the form (HSPICE): `SCALE=` and `M=` multiply, `MAX=` and
`MIN=` clamp, `ABS=1` takes the magnitude, `TC1=` and `TC2=` add
temperature coefficients, `IC=` sets the initial value. `FREQ`, `OPAMP`,
`NPWL`, `PPWL`, `AND`, `NAND`, `OR`, `NOR` and `TRANSFORMER` are refused.
The node name in that slot is checked against these words first, so do not
name a node `pole`, `value`, `table` or `delay` there.

`B` sources: `V=` and `I=` give a voltage or current, `Q=` a charge whose
time derivative flows. The expression can read `v(n)`, `v(a,b)`,
`i(Vsource)`, `time`, `temper` and parameters. Instance parameters may
follow the braced expression (`tc1=`, `reciproctc=1`, ...).

### Semiconductors and models

`.model name type(params)`: the type and `LEVEL=` select the device. The
[devices page](devices.md) has every type, LEVEL and model. Model bins
(`.model nch.1 ...`, `.model nch.2 ...` with `LMIN LMAX WMIN WMAX`) are
selected by the instance's L and W; `.option scale=` scales them.

## Dot cards

### Structure and parameters

| Card | Syntax | Notes |
|---|---|---|
| `.end` | `.end` | ends the deck; later lines are ignored |
| `.subckt` / `.ends` | `.subckt name ports... [p=v ...]` ... `.ends [name]` | nested up to 32 levels |
| `.param` | `.param name=value [name=value ...]` | global at top level, per instance inside a subcircuit |
| `.model` | `.model name type [(]params[)]` | |
| `.global` | `.global n1 n2 ...` | nets shared through every subcircuit level |
| `.connect` | `.connect a b` | joins two top-level nets |
| `.if` `.elseif` `.else` `.endif` | `.if (expr)` ... `.endif` | keeps the first branch whose condition is nonzero |

### Files

| Card | Syntax | Notes |
|---|---|---|
| `.include`, `.inc` | `.include "file"` | pastes the file; `.va`, `.vams`, `.veriloga`, `.v` and `.sv` files load as HDL instead |
| `.lib` | `.lib "file" section` | pastes one section; inside a library, `.lib section` ... `.endl` defines it |
| `.endl` | `.endl [section]` | closes the open section |
| `.hdl` | `.hdl "model.va"` | compiles and loads a Verilog-A (or Verilog `.v`) module |
| `.verilog` | `.verilog "design.v"` | loads a digital Verilog design |
| `.load` | `.load [FILE=]f [RUN=]` | HSPICE: pastes a saved `.ic`/`.nodeset` file; skipped with a warning when missing |
| `.vec` | `.vec 'file'` | HSPICE digital vector file, rewritten to PWL sources and `.dout` checks |
| `.alter` | `.alter` ... | HSPICE: the cards after it modify the deck for one more run; blocks are cumulative |
| `.osdi_include`, `.pre_osdi` | | refused: OSDI is never loaded |

Paths resolve against the directory of the file that names them, then
against each `.option search='dir'`. Includes nest up to 32 levels.

### Options

`.option`, `.options`, `.opt` and `.opts` are the same card:
`.options name=value ...`.

| Option | Default | Meaning |
|---|---|---|
| `reltol` (`relv`) | 1e-3 | relative convergence tolerance |
| `abstol` (`absi`) | 1e-12 | absolute current tolerance, A |
| `vntol` (`absv`) | 1e-6 | absolute voltage tolerance, V |
| `chgtol` | 1e-14 | charge tolerance, C |
| `gmin` (`gmindc`) | 1e-12 | conductance added across junctions, S |
| `itl1`, `itl2`, `itl4` | 100, 50, 10 | Newton iteration limits: operating point, DC sweep point, transient step |
| `trtol` | 7 | transient truncation-error factor |
| `method` | `trap` | `trap` (`trapezoidal`) or `gear` (`bdf`) |
| `maxord` | | Gear order; `maxord=1` with `gear` is backward Euler |
| `xmu` | 0.5 | trapezoidal damping, 0 to 0.5 (0 is backward Euler) |
| `temp` | 27 | circuit temperature, °C |
| `tnom` | 27 (HSPICE 25) | model reference temperature, °C |
| `delmax` | | transient step cap when `.tran` gives none |
| `gshunt`, `cshunt` | | R and C from every net to ground |
| `scale` | 1 | geometry scale for model binning |
| `wnflag` | 0 (HSPICE 1) | bin selection by per-finger W |
| `seed` | 1 | Monte Carlo seed |
| `sampling_method` | | `lhs` for Latin hypercube sampling |
| `runlvl`, `accurate`, `fast` | | HSPICE accuracy presets: set `trtol` |
| `em_recovery` | 1 | recovery factor for `.meas EM_AVG` |
| `search` | | HSPICE: an include search directory |

Other names are ignored (the HSPICE dialect warns about each).

### Initial conditions

| Card | Syntax | Notes |
|---|---|---|
| `.ic` | `.ic v(n1)=v1 v(n2)=v2 ...` | the start state of a `.tran ... uic` |
| `.dcvolt` | `.dcvolt v(n)=v ...` or `.dcvolt n v ...` | the same as `.ic` |
| `.nodeset` | `.nodeset v(n)=v ...` | a starting guess for the operating point's first Newton solve |
| `.temp` | `.temp t` | one value: the circuit temperature. Three values (ngspice): a temperature sweep analysis. A list (HSPICE): every analysis at each |

### Output

| Card | Syntax | Notes |
|---|---|---|
| `.save` | `.save v(out) i(v1) ...` | write only these vectors. HSPICE dialect: `.save [TYPE=NODESET\|IC] [FILE=] [LEVEL=ALL\|TOP\|SELECT\|NONE] [TIME=]` writes the operating point as a loadable file |
| `.print`, `.plot`, `.probe`, `.graph`, `.width`, `.title` | | accepted and ignored: every vector is written |
| `.protect`, `.unprotect`, `.prot`, `.unprot` | | accepted and ignored |
| `.store` | | HSPICE checkpointing: a warning, nothing written |
| `.stim` | `.stim [tran] pwl\|data ...` | HSPICE: writes transient signals as PWL sources or a `.data` table |

### `.meas`

`.meas` and `.measure` are the same card. [Chapter 7](../learn/measure.md)
teaches them.

```text
.meas tran|ac|dc|fft|trannoise|dcmatch|acmatch|lstb|phasenoise|ptdnoise name FUNCTION ...
.meas tran_cont|ac_cont|dc_cont name ...
```

| Function | Form |
|---|---|
| `TRIG` ... `TARG` (also `DELAY`) | `TRIG sig VAL= RISE\|FALL\|CROSS= [TD=] TARG sig VAL= ...` |
| `FIND`, `WHEN` | `FIND sig AT=x`, `FIND sig WHEN sig2=v`, `WHEN sig=v` |
| `AVG`, `RMS`, `INTEG` (`INTEGRAL`), `MIN`, `MAX`, `PP`, `MIN_AT`, `MAX_AT` | `func sig [FROM= TO=]` |
| `DERIV` (`DERIVATIVE`) | `DERIV sig AT=x` or `WHEN ...` |
| `PARAM` | `PARAM='expr'` over earlier results and parameters |
| `ERR`, `ERR1`, `ERR2`, `ERR3` | HSPICE error between two signals |
| `THD`, `SNR`, `SNDR`, `ENOB`, `SFDR` | on an `.fft` plot, with `NBHARM= MINFREQ= MAXFREQ= BINSIZ=` |
| `EM_AVG` | electromigration average current |
| `JITTER` | time interval error of a clock's edges (RMS, peak-to-peak, period): `.jitter tran TRIG v(clk) VAL= [TD=] [RISE\|FALL\|CROSS=]` |

Common keywords: `RISE=`, `FALL=`, `CROSS=` (a count, or `LAST`), `TD=`,
`FROM=`, `TO=`, `AT=`, `VAL=`, `GOAL=`, `WEIGHT=`, `MINVAL=`. Signals:
`v(n)`, `v(a,b)`, `i(Vsource)`, `par('expr')`, and in AC `vdb`, `vm`, `vp`,
`vr`, `vi`. HSPICE's `.check`, `.dout`, `.biaschk`, `.power` and `.jitter`
are read as measurements too:

| Card | Reports |
|---|---|
| `.check rise\|fall\|slew (min max) nodes` | edges whose duration is outside [min, max] |
| `.check setup\|hold (ref RISE\|FALL d RISE\|FALL) nodes` | setup and hold violations |
| `.check edge (ref RISE\|FALL min max RISE\|FALL) nodes` | missing edges |
| `.check irdrop (v d) nodes` | stretches beyond `v` longer than `d` |
| `.check global_level (hi lo hi_th lo_th)` | the default logic thresholds |
| `.dout nd [VTH \| VLO VHI] (t s ...)` | states a node fails to hold |
| `.biaschk 'expr' [max= min= tstart= tstop=]` | stretches of an expression outside its limits |
| `.power signal [FROM= TO=]` | average, RMS, max and min power |

### Sweeps and statistics { #statistics }

| Card | Syntax | Notes |
|---|---|---|
| `.step` | `.step [lin\|dec\|oct] [param] name start stop step`, or `... list v1 v2 ...` | reruns every analysis per point; `name` is a parameter, `temp` or a source/element |
| `.data` / `.enddata` | `.data name p1 p2 ... v11 v12 ... .enddata` | HSPICE table for `SWEEP DATA=name` (also `MER`/`LAM` file forms) |
| `.variation` / `.end_variation` | `.variation .local_variation .element_variation r r=5 % ...` | HSPICE variation block for Monte Carlo and mismatch |
| `.mc`, `.montecarlo` | `.mc N [sigma]` | see [analyses](analyses.md#mc) |

On any analysis card, HSPICE's `SWEEP` tail runs the card once per point:
`SWEEP DATA=name`, `SWEEP MONTE=n [FIRSTRUN=k]`, `SWEEP MONTE=list(10 20:30)`,
`SWEEP OPTIMIZE=name RESULTS=m1,m2 MODEL=optmod`. On `.dc`, `DATA=` and
`MONTE=` work without the word `SWEEP`.

Statistical functions in expressions: `agauss(nom, abs, sigmas)`,
`gauss(nom, rel, sigmas)`, `aunif(nom, abs)`, `unif(nom, rel)`,
`limit(nom, var)`. They return `nom` unless a Monte Carlo sweep or
`.option seed` (ngspice dialect) is active. On a `.model` value,
`LOT/GAUSS=x%` and `DEV/GAUSS=y%` draw once per model and once per device.

### Reliability and noise sampling (HSPICE)

| Card | Syntax |
|---|---|
| `.mosra` | `.mosra RelTotalTime= [RelStartTime= RelStep= SimMode=0\|2 RelMode= AgingStart= AgingStop= HciThreshold= NbtiThreshold= DegF=]` |
| `.appendmodel` | `.appendmodel src MOSRA dst NMOS\|PMOS` |
| `.sample` | `.sample FS= [TOL= NUMF= MAXFLD= BETA=]`: noise folding for sampled `.noise` spectra |

### ngspice control blocks

`.control` ... `.endc` is skipped with a warning: ESPice runs the analysis
cards in the deck, not ngspice scripts. A `pre_osdi` line inside the block
is still an error.

## Analysis cards

Each has a section in [Analyses](analyses.md):

`.op` `.dc` `.ac` `.tran` `.noise` `.tf` `.sens` `.pz` `.disto` `.four`
`.fft` `.sp` (`.lin`, `.net`) `.stb` `.lstb` `.pss` (`.sn`, `.snosc`)
`.pac` (`.snac`) `.pnoise` (`.snnoise`, `.ptdnoise`) `.pxf` (`.snxf`) `.hb`
(`.hbosc`) `.hbac` `.hbxf` `.hbnoise` `.hblin` `.phasenoise` `.qpss`
`.envelope` (`.envlp`) `.matex` `.trannoise` (`.tran_noise`) `.mc`
(`.montecarlo`) `.temp` `.dcmatch` `.acmatch` `.dcsens` `.dcxf` `.acxf`
`.dcinc` `.acphasenoise`
