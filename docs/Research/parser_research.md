# Parser Crate Research — BigOSpice

**File:** `crates/parser/src/tokenizer.rs` (main parser, ~300KB)
**Files:** `types.rs`, `lib.rs`, `tests.rs`

---

## 1. Tokenizer / Lexer

**Struct:** `Lexer` — byte-slice lexer, input pre-lowercased at construction.

### Token Types

```rust
pub enum Token {
    Word(String),          // Identifiers, node names, model names
    Number(f64),           // Numeric values (SI suffix already resolved)
    Equals,                // '='
    LeftParen,             // '('
    RightParen,            // ')'
    Comma,                 // ','
    Plus,                  // '+' (mid-line only; line-start is continuation)
    Minus,                 // '-'
    Star,                  // '*' (mid-line only; line-start is comment)
    Slash,                 // '/'
    Dot(String),           // .directive: .PARAM, .MODEL, .TRAN, etc.
    Newline,               // End of logical statement
    LeftBrace,             // '{' for behavioral expressions
    RightBrace,            // '}'
    QuotedString(String),  // Double-quoted: "filename.csv" — opaque string
    SingleQuoteExpr(String), // Single-quoted HSPICE expr: 'R0*SCALE' — evaluated as arithmetic
    Eof,
}
```

### Lexer Behavior

- **Case insensitivity:** Input pre-lowercased via `input.to_ascii_lowercase()` in `Lexer::new()`. No per-token lowercasing needed.
- **Line continuation:** `+` at start of line collapses with previous logical line. Blank lines and comment-only lines are skipped during continuation detection.
- **Full-line comments:** `*` at start of line (`at_line_start=true`) skips to end of line.
- **Inline comments:** `;` or `$` skips to end of line.
- **SI suffixes on numbers:** `1k` → 1000.0, `100n` → 1e-7, `2.2meg` → 2.2e6, `1G` → 1e9. Uses `incspice_utility::si_multiplier()`.
- **Exponent parsing:** `1e-3`, `1E+5` handled specially; `e` followed by non-digit is treated as SI suffix.
- **Dot directives:** `.` followed by alphanumeric/underscore → `Dot(String)`.
- **Colon stripping:** Trailing `:` is silently consumed from words (e.g., `PARAMS:` tokenizes as `Word("params")`).
- **Word characters:** alphanumeric + `_` + `#`.
- **Unknown characters** are skipped with a parse error.

### Number Parsing Detail

```rust
// read_number() logic:
// 1. Read digits, decimal, exponent (e/E with sign/digit)
// 2. Consume SI suffix (alphabetic sequence)
// 3. si_multiplier() lookup — returns multiplier or None
// 4. If suffix not found, rewind and parse as plain number
```

---

## 2. Expression AST

**File:** `types.rs` — `Expression` enum and `Op` enum.

```rust
pub enum Op { Add, Sub, Mul, Div, Pow }

pub enum Expression {
    Literal(f64),
    Param(String),                    // Named parameter reference
    BinOp(Op, Box<Expression>, Box<Expression>),
    UnaryMinus(Box<Expression>),
    Func(String, Vec<Expression>),   // sqrt(x), abs(x), if(cond,then,else), etc.
    NodeVoltage(String),             // V(node) or differential V(n1,n2) via Sub
}
```

### Supported Functions in `eval_expression()`

| Function | Arity | Description |
|----------|-------|-------------|
| `sqrt` | 1 | Square root |
| `abs` | 1 | Absolute value |
| `exp` | 1 | Exponential |
| `log`, `ln` | 1 | Natural logarithm |
| `log10` | 1 | Base-10 logarithm |
| `log2` | 1 | Base-2 logarithm |
| `sin`, `cos`, `tan` | 1 | Trigonometry |
| `asin`, `acos`, `atan`, `atan2` | 1/2 | Inverse trig |
| `sinh`, `cosh`, `tanh` | 1 | Hyperbolic trig |
| `asinh`, `acosh`, `atanh` | 1 | Inverse hyperbolic |
| `pow` | 2 | Power |
| `min`, `max` | 2 | Min/max |
| `sign`, `sgn` | 1 | Signum |
| `ceil`, `floor`, `round`, `nint` | 1 | Rounding |
| `int` | 1 | Truncation |
| `db` | 1 | 20*log10(\|x\|) in dB |
| `uramp` | 1 | max(x, 0) |
| `u` | 1 | Unit step |
| `pwr` | 2 | \|x\|^y |
| `pwrs` | 2 | sign(x)*\|x\|^y |
| `hypot` | 2 | sqrt(x²+y²) |
| `limit` | 3 | clamp(x, min, max) |
| `if` | 3 | if(cond, then, else) |
| `gauss` | 1 | Gaussian with mean=0, std=sigma (uses thread-local xorshift64 PRNG) |
| `agauss` | 2 | Gaussian with mean=mu, std=sigma |
| `unif`, `flat` | 1 | Uniform in [-range, range] |
| `aunif` | 2 | Uniform in [mu-range, mu+range] |
| `optval` | 1+ | Returns init value (bounds stored separately) |

### Symbolic Differentiation

`Expression::differentiate(var: &str)` returns `d(self)/d(var)` using chain rule. Supports:
- `sqrt`, `abs`, `exp`, `log`/`ln`, `log10`, `sin`, `cos`, `pow`
- `min`/`max` → returns 0 (not differentiable cleanly)

---

## 3. Expression Parser

**Struct:** `ExprParser<'a>` — recursive-descent parser operating on `&[Token]`.

Operator precedence (lowest to highest):
1. `+`, `-` (addition/subtraction)
2. `*`, `/` (multiplication/division)
3. `**` (power — two consecutive `*` tokens)
4. Unary `-`, `+`

### Entry Points

```rust
pub fn parse_expression(tokens: &[Token]) -> Result<Expression, SimError>
pub fn parse_brace_expression(tokens: &[Token]) -> Result<(Expression, usize), SimError>
pub fn eval_expression(expr: &Expression, params: &AHashMap<String, f64>) -> Result<f64, SimError>
```

---

## 4. Element Line Parsing

**Entry:** `SpiceParser::parse_element_line()` — dispatches on first character of element name.

### Dispatch Table

| Prefix | Device | Parser Method |
|--------|--------|---------------|
| `R` | Resistor | `parse_two_terminal(..., DeviceKind::Resistor, ..., "resistance")` |
| `C` | Capacitor | `parse_two_terminal(..., DeviceKind::Capacitor, ..., "capacitance")` |
| `L` | Inductor | `parse_two_terminal(..., DeviceKind::Inductor, ..., "inductance")` |
| `V` | Voltage Source | `parse_source(..., DeviceKind::VoltageSource, ...)` |
| `I` | Current Source | `parse_source(..., DeviceKind::CurrentSource, ...)` |
| `D` | Diode | `parse_diode(...)` |
| `M` | MOSFET | `parse_mosfet(...)` |
| `Q` | BJT | `parse_bjt(...)` |
| `J` | JFET | `parse_jfet(...)` |
| `Z` | MESFET | `parse_mesfet(...)` |
| `E` | VCVS | `parse_vcvs(...)` |
| `G` | VCCS | `parse_vccs(...)` |
| `H` | CCVS | `parse_ccvs(...)` |
| `F` | CCCS | `parse_cccs(...)` |
| `T` | Transmission Line | `parse_tline(...)` |
| `O` | Lossy Transmission Line | `parse_ltra(...)` |
| `U` | Uniform RC Line | `parse_urc(...)` |
| `W` | W-element (lossy wire) | `parse_w_element(...)` |
| `K` | Mutual Inductance | `parse_k_element(...)` — stored in `pending_k_elements` |
| `B` | Behavioral Source | `parse_bsource_pending(...)` — stored in `pending_bsources` |
| `X` | Subcircuit Instance | `parse_subckt_instance_top(...)` — stored in `pending_subckt_instances` |
| `A` | XSPICE A-device | `parse_a_device_pending(...)` — stored in `pending_a_devices` |
| `P` + `ort*` | Port | `parse_port(...)` |

### Two-Terminal Elements (R, C, L)

```spice
Rname NODE+ NODE- <value> [key=value...]
```

- Collects 2 node names
- Attempts bare numeric value or `{expr}` via `tokens_to_numeric_or_brace()`
- Remaining tokens parsed as `key=value` params
- If bare value found, also adds `value_param` ("resistance"/"capacitance"/"inductance") to params

### Voltage/Current Sources (V, I)

```spice
Vname NODE+ NODE- [DC <val>] [AC <mag> [phase]] [waveform]
```

Waveforms supported (via `emit_waveform_params`):

| Kind | Numeric Code | Parameters |
|------|-------------|------------|
| `PULSE(v1 v2 td tr tf pw per)` | 1 | `pulse_v1`, `pulse_v2`, `pulse_td`, `pulse_tr`, `pulse_tf`, `pulse_pw`, `pulse_per` |
| `SIN(vo va freq td theta)` | 2 | `sin_vo`, `sin_va`, `sin_freq`, `sin_td`, `sin_theta` |
| `PWL(t0 v0 t1 v1 ...)` | 3 | `pwl_count`, `pwl_t{i}`, `pwl_v{i}` |
| `EXP(v1 v2 td1 tau1 td2 tau2)` | 4 | `exp_v1`, `exp_v2`, `exp_td1`, `exp_tau1`, `exp_td2`, `exp_tau2` |
| `SFFM(vo va fc mdi fs)` | 5 | `sffm_vo`, `sffm_va`, `sffm_fc`, `sffm_mdi`, `sffm_fs` |
| `PWL FILE="..."` | 6 | Path encoded as byte-per-param |
| `AM(vo va fc fm td)` | 7 | `am_vo`, `am_va`, `am_fc`, `am_freq`, `am_td` |
| `TRNOISE(na nt nalpha namp [td])` | 8 | `trnoise_na`, `trnoise_nt`, `trnoise_nalpha`, `trnoise_namp`, `trnoise_td` |
| `TRRANDOM(type ts td param1 param2)` | 9 | `trrandom_kind`, `trrandom_tstep`, `trrandom_td`, `trrandom_param`, `trrandom_mean` |
| `PWL ... R=<val>` (REPEAT) | 10 | PWL with repeat period |

### Diode (D)

```spice
Dname ANODE CATHODE MODELNAME [key=value...]
```

- 2 nodes + model name + optional key=value params
- DeviceKind::Diode

### MOSFET (M)

```spice
Mname DRAIN GATE SOURCE BULK MODELNAME [W=...] [L=...] [key=value...]
```

- 4 nodes + model name + key=value params
- DeviceKind::MosfetN (polarity resolved later from model)

### BJT (Q), JFET (J), MESFET (Z)

Similar patterns: 3 nodes + model name + params.

### Controlled Sources (E, G, H, F)

#### Standard Linear Form

```spice
Ename N+ N- NC+ NC- <gain>    // VCVS: E
Gname N+ N- NC+ NC- <gm>      // VCCS: G
Hname N+ N- VN+ VN- <Rh>      // CCVS: H
Fname N+ N- VN+ VN- <gain>    // CCCS: F
```

#### POLY(n) Form

```spice
E n+ n- POLY(1) (vc1+ vc1-) c0 c1 c2 ...
G n+ n- POLY(2) (vc1+ vc1-) (vc2+ vc2-) c0 c1 c2 c3 ...
```

- Degree specifies number of controlling node pairs
- Each pair is `(node+ node-)`
- Remaining tokens are polynomial coefficients

#### LAPLACE Form (ngspice style)

```spice
E n+ n- LAPLACE {expr} (b0 b1 ...) (a0 a1 ...)
G n+ n- LAPLACE {expr} (b0 b1 ...) (a0 a1 ...)
```

- Input signal: `{expr}` (parsed as behavioral expression)
- Transfer function: H(s) = (b0 + b1·s + ...) / (a0 + a1·s + ...)
- **Supported expansions:**
  - Pure gain: H(s) = K → behavioral B-source with gain
  - First-order LP: H(s) = K / (1 + τ·s) → expanded to B-source + R + C subcircuit

#### TABLE Form

```spice
E n+ n- TABLE {expr} = (x0,y0) (x1,y1) ...
G n+ n- TABLE {expr} = (x0,y0) (x1,y1) ...
```

#### VALUE Form

```spice
E n+ n- VALUE {expr}
E n+ n- VALUE = {expr}
```

### Behavioral Sources (B)

```spice
Bname NODE+ NODE- <expr>
```

- Expression parsed via `parse_bsource_rhs()` → `BehavioralExpr` AST
- Stored in `pending_bsources` (cannot fit in ElementStatement params)
- Supports: `V(node)`, `V(n1,n2)`, arithmetic operators, functions
- Differentiated for MNA stamping

### Subcircuit Instance (X)

```spice
Xname NODE1 NODE2 ... SUBCKTNAME [PARAMS: key=value ...]
```

- Last token is subcircuit definition name
- All preceding tokens are node connections
- `PARAMS:` keyword handled (colon stripped by lexer)
- Key=value pairs are instance-level parameter overrides
- Stored in `pending_subckt_instances` for expansion in `build_circuit()`

### XSPICE A-Devices (A)

```spice
Aname [in1 in2 ...] [out1 out2 ...] MODELNAME
Aname (in1) (out1) MODELNAME   // Parenthesized form
```

- Input/output nodes collected
- Model name references `.MODEL` card with XSPICE code model
- Stored in `pending_a_devices`

### Mutual Inductance (K)

```spice
Kname L1_name L2_name <coupling_coefficient>
```

- Both inductor names as bare identifiers (not node references)
- Coupling coefficient k ∈ (0, 1]
- Stored in `pending_k_elements`; resolved during `build_circuit()`

---

## 5. Analysis Directives

### `.OP` — DC Operating Point

```spice
.OP
```

Parsed as `AnalysisKind::DcOp`, no parameters.

### `.DC` — DC Sweep

```spice
.DC [LIN] <src_name> <start> <stop> <step>
.DC DEC <src_name> <start> <stop> <points_per_decade>
.DC OCT <src_name> <start> <stop> <points_per_octave>
.DC LIST <val1> <val2> ...
```

Parameters stored as `("dc_start", f64)`, `("dc_stop", f64)`, `("dc_step", f64)`, or kind-specific variants.

### `.TRAN` — Transient Analysis

```spice
.TRAN [TSTEP] <TSTOP> [TSTART [TMAX]] [UIC]
```

- `UIC` keyword triggers `ic=...` initial condition mode
- Parameters: `("tran_tstop", f64)`, `("tran_tstart", f64)`, `("tran_tstep", f64)`, `("tran_tmax", f64)`, `("tran_uic", f64)` (0.0 or 1.0)

### `.AC` — AC Small-Signal Analysis

```spice
.AC [LIN|DEC|OCT] <points> <fstart> <fstop>
```

- Sweep type: `("ac_sweep", "lin"|"dec"|"oct")`
- Parameters: `("ac_points", f64)`, `("ac_fstart", f64)`, `("ac_fstop", f64)`

### `.NOISE` — Noise Analysis

```spice
.NOISE V(<out_node>) <src_name> [LIN|DEC|OCT] <points> <fstart> <fstop>
```

Parsed into `NoiseStatement` struct (not `AnalysisStatement`) with fields:
- `output_node: String`
- `input_source: String`
- `sweep_type: String`
- `npoints: usize`
- `fstart: f64`
- `fstop: f64`

### `.FOUR` — Fourier Analysis

```spice
.FOUR <f0> [v(node) v(node) ...]
```

- Fundamental frequency + output node list
- `AnalysisKind::Four` with params: `("four_f0", f64)`, `("four_harms", count)` (inferred)

### `.FFT`

```spice
.FFT V(<node>) NP [window] [start] [stop]
```

Parsed into `FftStatement` with `npoints`, `window` ("rect"|"hanning"|"hamming"|"blackman"|"kaiser"), optional `tstart`/`tstop`.

### `.SENS` — Sensitivity Analysis

```spice
.SENS <output> [param1 param2 ...]
```

`AnalysisKind::Sens { output: SensOutputSpec, params: Vec<String> }`

### `.HB` — Harmonic Balance

```spice
.HB <f1> [<f2>] <nharmonics>
```

Single-tone and two-tone forms distinguished by number of numeric args.

### `.DISTO` — Distortion Analysis

```spice
.DISTO <f1> [numf2 [f2overf1 [fstart] [fstop]]]
```

Parsed into `DistoStatement` with `f1`, optional `f2`, `output_node`, `a2`, `a3`, optional `fstart`/`fstop`.

### `.STEP` — Parameter Sweep

```spice
.STEP [LIN|DEC|OCT|LIST] <param> <start> <stop> <step|points>
.STEP <param> <start> <stop> <step>   (implicit LIN)
.STEP LIST <param> <val1> <val2> ...
.STEP DATA <dataname>
```

`StepKind` enum: `Lin`, `Dec`, `Oct`, `List`, `LinImplicit`, `Data`.

---

## 6. Model Cards

### `.MODEL`

```spice
.MODEL <name> <type> [(param=val ...)]
```

- Model type strings: `nmos`, `pmos`, `d`, `npn`, `pnp`, `njf`, `pjf`, `nmf`, `pmf`
- `O.4` statistical params: `LOT=5%` → `val/100.0`
- Inline params (without parens) also collected and merged

### `.BINMODEL` (T.11)

```spice
.BINMODEL <name> NMOS|PMOS [model1 model2 ...]
```

Groups multiple `.MODEL` entries for geometry-based MOSFET model selection. Each entry has `lmin`/`lmax`/`wmin`/`wmax` bounds.

### `.DISTRIBUTION` (T.12)

```spice
.DISTRIBUTION <name> UNIFORM|GAUSSIAN|LOGNORM|BIMODAL [params...]
```

Custom statistical distributions for Monte Carlo analysis.

---

## 7. Parameter Expressions

### `.PARAM`

```spice
.PARAM <name>=<value>
.PARAM <name>={<expr>}
.PARAM <name>=<bare_expr>
```

Forms supported:
1. **Brace expression:** `name = { 2*pi*freq }` → parsed via `parse_brace_expression()`
2. **Bare numeric:** `name = 1k` → `tokens_to_number()`
3. **Bare expression:** `name = 2*pi*f` → expression parsed to end of line

`OPTVAL(init, lower, upper)` detected and stored in `optimize_params`.

### `.FUNC`

```spice
.FUNC <name>(arg1, arg2, ...) = <expr>
.FUNC <name>(arg1, arg2, ...) = {<expr>}
```

- `FuncDef` stored in `netlist.funcs`
- Body is parsed `Expression` referencing args via `Expression::Param`

### `.GLOBAL_PARAM`

```spice
.GLOBAL_PARAM <name>=<value> ...
```

Global parameters visible in all subcircuit scopes (Xyce semantics).

---

## 8. Subcircuit Definition

```spice
.SUBCKT <name> <port1> <port2> ... [PARAMS: key=val ...]
  <element lines>
  X<instance> ...             (nested X instances)
.ENDS
```

- `SubcircuitDef` stores: `name`, `ports: Vec<String>`, `default_params`, `body: Vec<ElementStatement>`, `nested_instances`
- Expansion during `build_circuit()` via `expand_instances()`
- Node mangling: internal nodes prefixed with `instance_name.`
- Cycle detection via `expansion_stack`
- Port count mismatch checked at expansion time

---

## 9. Additional Directives

### `.IC` / `.NODESET`

```spice
.IC V(<node>)=<value>
.NODESET V(<node>)=<value>
```

Parsed into `initial_conditions: Vec<(String, f64)>` and `node_sets: Vec<(String, f64)>`.

### `.TEMP`

```spice
.TEMP <t1> [t2] ...
```

Accumulated into `temperatures: Vec<f64>`.

### `.GLOBAL`

```spice
.GLOBAL <node1> <node2> ...
```

Nodes visible inside all subcircuits without explicit port passing.

### `.SAVE` / `.PRINT` / `.PLOT`

```spice
.SAVE [DC|TRAN|AC|OP|NOISE|ALL] [V(node) V(n1,n2) I(vname) V(*) I(*) *] [FILE="..."] [FORMAT=CSV|GNUPLOT|RAW|PROBE|TECPLOT] [DELIMITER=","]
```

SaveSpec variants:
- `NodeVoltage(String)` — V(node)
- `NodeVoltageDiff(String, String)` — V(n1,n2)
- `BranchCurrent(String)` — I(vname)
- `Power(String)` — P(element) / W(element)
- `NoiseDensity(String)` — N(node)
- `AllVoltages` — V(*)
- `AllCurrents` — I(*)
- `All` — *
- `ComputedExpr(String)` — par('expr')

### `.MEAS` / `.MEASURE`

```spice
.MEAS [TRAN|AC|DC] <name> <評価式>
```

Raw tokens stored in `MeasureStatement.tokens: Vec<String>` for post-processing.

### `.EXTRACT` (HSPICE W.5)

```spice
.EXTRACT [TRAN|AC|DC] <label>=<expr>
```

Parsed into `ExtractSpec` with `analysis`, `label`, `expr` string.

### `.DATA` / `.ENDDATA`

```spice
.DATA <name> <param1> <param2> ...
<val1a> <val1b>
<val2a> <val2b>
.ENDDATA
```

Parsed into `DataBlock` with `name`, `params: Vec<String>`, `rows: Vec<Vec<f64>>`.

### `.CONNECT` (W.6)

```spice
.CONNECT <net1> <net2>
```

Pairs of net names to merge after circuit build.

### `.ROL` (W.4)

```spice
.ROL LIFETIME=<t> [TEMP=<t>] [EM=<0|1>] [NBTI=<0|1>] [HCI=<0|1>]
```

Reliability/aging analysis config, stored in `rol_config: Option<RolConfig>`.

### `.IF` / `.IFDEF` / `.IFNDEF` / `.ELSE` / `.ELSEIF` / `.ENDIF`

```spice
.IF {<cond>}
.IFDEF <param_name>
.IFNDEF <param_name>
```

Condition evaluated against `.PARAM` map at parse time. Active branch parsed; inactive branches skipped.

### `.OPTIONS`

```spice
.OPTIONS <key>=<val> ...
```

Accumulated into `incspice_core::SimOptions` struct.

### `.INCLUDE` / `.LIB`

Pre-processing step before main parsing:
- `.INCLUDE "filename"` — recursive file inlining with cycle detection
- `.LIB "filename" <section>` — extract named section from library file
- `.LIB <section> ... .ENDL` — inline definition block

### `.control` / `.endc`

```spice
.control
<raw statements>
.endc
```

Lines stored verbatim as `ControlStatement { raw: String }` in `ControlBlock.lines`.

---

## 10. Circuit Construction (`build_circuit`)

After tokenization and parsing:

1. **Subcircuit expansion** — `expand_instances()` recursively expands all `X` instances using `SubcircuitDef` map
2. **Pending B-sources** — `PendingBsource` records converted to `BehavioralExpr` and stamped into MNA
3. **Pending K elements** — Mutual inductance coupling coefficient applied to inductor pairs
4. **Pending A-devices** — XSPICE devices routed to digital event engine
5. **Model bin selection** — `.BINMODEL` resolved based on drawn L/W at MOSFET instantiation
6. **Global node handling** — `.GLOBAL` nodes made visible in all subcircuit scopes
7. **Connect directives** — `.CONNECT` pairs merged into single net
8. **Parameter resolution** — `.PARAM` expressions evaluated against current param map

---

## 11. Key Internal Helpers

### `token_to_node_name(&Token) -> Result<String, SimError>`

Handles `Word` (identifier), `Number` (integer node names like `0`, `1`), and integer floats.

### `tokens_to_numeric_or_brace(&[Token], &AHashMap) -> Option<(f64, usize)>`

Tries:
1. Single `Token::Number` → return value
2. `Token::Minus` + Number → negative value
3. `Token::LeftBrace` → `parse_brace_expression()` → `eval_expression()` → value

### `try_parse_kv_param(&[Token]) -> Option<(String, f64, usize)>`

Attempts to parse `Word Equals (Number | Minus Number | LeftBrace ... RightBrace)` triplet.

### `tokens_to_signed_number(&[Token]) -> Option<(f64, usize)>`

Handles standalone sign tokens before numbers.

### `collect_paren_args(&[Token]) -> Vec<f64>`

Collects numeric args from waveform calls, handling both parenthesized `PULSE(...)` and bare positional forms.

---

## 12. ParsedNetlist Structure

```rust
pub struct ParsedNetlist {
    pub title: String,
    pub elements: Vec<ElementStatement>,
    pub models: Vec<ModelStatement>,
    pub analyses: Vec<AnalysisStatement>,
    pub params: AHashMap<String, f64>,
    pub subcircuits: Vec<SubcircuitDef>,
    pub pending_subckt_instances: Vec<PendingSubcktInstance>,
    pub initial_conditions: Vec<(String, f64)>,
    pub node_sets: Vec<(String, f64)>,
    pub globals: Vec<String>,
    pub temperatures: Vec<f64>,
    pub options: incspice_core::SimOptions,
    pub measures: Vec<MeasureStatement>,
    pub noise_statements: Vec<NoiseStatement>,
    pub disto_statements: Vec<DistoStatement>,
    pub fft_statements: Vec<FftStatement>,
    pub steps: Vec<StepDirective>,
    pub funcs: AHashMap<String, FuncDef>,
    pub saves: Vec<SaveDirective>,
    pub param_exprs: Vec<(String, Expression)>,
    pub data_blocks: Vec<DataBlock>,
    pub control_blocks: Vec<ControlBlock>,
    pub global_params: AHashMap<String, f64>,
    pub bin_models: Vec<BinModel>,
    pub distributions: Vec<CustomDistribution>,
    pub optimize_params: Vec<OptimizeParam>,
    pub connect_directives: Vec<(String, String)>,
    pub extract_specs: Vec<ExtractSpec>,
    pub rol_config: Option<incspice_core::RolConfig>,
}
```

---

## 13. Usage Example

```rust
use incspice_parser::{SpiceParser, Lexer, parse_expression, eval_expression};

let (circuit, analyses, options) = SpiceParser::parse_file(Path::new("netlist.sp"))?;
let (circuit, analyses, options, extracts) = SpiceParser::parse_netlist(input)?;

// Tokenize and parse expression manually
let mut lexer = Lexer::new("{2 * pi * freq}");
let tokens = lexer.tokenize_all()?;
let expr = parse_expression(&tokens)?;
let value = eval_expression(&expr, &params)?;
```

---

## 14. Limitations / Notes

- **LAPLACE**: Only pure gain and first-order lowpass are implemented. Higher-order transfer functions return descriptive errors.
- **POW (`**`)**: Two consecutive `*` tokens parsed as power operator; single `*` is multiplication.
- **Node names**: Numeric node names (0, 1, 2...) converted to string form. Integer-only floats (`1.0`) also accepted.
- **Statistical functions** (`gauss`, `unif`, etc.) use thread-local xorshift64 PRNG — deterministic within a thread.
- **HSPICE-specific**: `SingleQuoteExpr` (single-quoted arithmetic), `OPTVAL`, `DIST=`, `TABLE`, `LAPLACE`, `DATA` sweep are extensions over vanilla SPICE3.
- **Subcircuit expansion** is done eagerly at parse time during `build_circuit()`, not lazily.
