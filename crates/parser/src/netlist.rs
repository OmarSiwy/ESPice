use ahash::AHashMap;
use pisim_core::DeviceKind;

use crate::expr::Expression;

/// A parsed `.NOISE` statement, storing the string fields that cannot be
/// represented in the numeric `AnalysisStatement.params` vec.
#[derive(Debug, Clone)]
pub struct NoiseStatement {
    /// Output node specification, e.g. `"out"` (from `V(out)`).
    pub output_node: String,
    /// Input source name, e.g. `"V1"`.
    pub input_source: String,
    /// Sweep type string: `"dec"`, `"oct"`, or `"lin"`.
    pub sweep_type: String,
    /// Points per decade/octave (or total for linear).
    pub npoints: usize,
    /// Start frequency [Hz].
    pub fstart: f64,
    /// Stop frequency [Hz].
    pub fstop: f64,
}

/// A parsed `.DISTO f1 numf2 f2overf1 [fstart] [fstop]` statement.
///
/// Phase 3.4 — small-signal distortion via the Volterra kernel approach.
/// `.DISTO` in SPICE2/SPICE3 accepts:
///   `.DISTO f1 [numf2 [f2overf1 [fstart] [fstop]]]`
///
/// For PiSIM we store the tones directly: `f1`, an optional `f2` (resolved
/// from `numf2 != 0` with `f2 = f1 * f2overf1`), an output node, and the
/// analytic Volterra coefficients (`a2`, `a3`) supplied via `.OPTIONS`-style
/// keys `a2=…`, `a3=…` on the same line.
#[derive(Debug, Clone)]
pub struct DistoStatement {
    /// Fundamental frequency f1 [Hz].
    pub f1: f64,
    /// Optional second tone f2 [Hz] (for IM2/IM3). `None` when `numf2 == 0`
    /// or the second tone wasn't given.
    pub f2: Option<f64>,
    /// Output node name (defaults to the first non-ground node when empty).
    pub output_node: String,
    /// Second-order Volterra coefficient (a2) — used when the caller wants to
    /// override the analytic default.
    pub a2: f64,
    /// Third-order Volterra coefficient (a3).
    pub a3: f64,
    /// Optional frequency-range stop (parsed but unused by the analysis).
    pub fstart: Option<f64>,
    pub fstop: Option<f64>,
}

/// A parsed `.FFT vector NP [window] [start] [stop]` statement.
///
/// Phase 3.4 — FFT of a transient waveform.
#[derive(Debug, Clone)]
pub struct FftStatement {
    /// Output variable ("vector"), e.g. `"out"` from `V(out)`.
    pub output_node: String,
    /// Number of FFT points (the analysis rounds up to the next power of two).
    pub npoints: usize,
    /// Window name: one of `"rect"`, `"hanning"`, `"hamming"`, `"blackman"`,
    /// `"kaiser"`.  Defaults to `"hanning"`.
    pub window: String,
    /// Optional start time [s] for the transient slice.
    pub tstart: Option<f64>,
    /// Optional stop time [s] for the transient slice.
    pub tstop: Option<f64>,
}

/// A parsed `.MEAS` / `.MEASURE` statement, stored as raw string tokens for
/// post-processing after simulation.  The actual evaluation happens in
/// `pisim_analysis::measure`.
#[derive(Debug, Clone)]
pub struct MeasureStatement {
    /// The raw whitespace-split tokens from the directive line (including the
    /// analysis type token, e.g. `["TRAN", "risetime", "TRIG", ...]`).
    pub tokens: Vec<String>,
}

/// A single `.EXTRACT` label=expression entry (HSPICE W.5).
#[derive(Debug, Clone)]
pub struct ExtractSpec {
    /// Analysis type: `"tran"`, `"ac"`, or `"dc"`.
    pub analysis: String,
    /// Measurement name (the label before `=`).
    pub label: String,
    /// Raw expression string (e.g. `ymax(v(out))`).
    pub expr: String,
}

/// A `.STEP` parameter sweep directive — drives a generic ParamSweep runner.
///
/// Variants describe HOW the values for the parameter are generated:
///
/// * `Lin` : `start, stop, step`               (linear)
/// * `Dec` : `start, stop, points_per_decade`
/// * `Oct` : `start, stop, points_per_octave`
/// * `List`: explicit list of values
#[derive(Debug, Clone, PartialEq)]
pub enum StepKind {
    /// `.STEP LIN {param} start stop step`
    Lin { start: f64, stop: f64, step: f64 },
    /// `.STEP DEC {param} start stop points_per_decade`
    Dec { start: f64, stop: f64, ppd: usize },
    /// `.STEP OCT {param} start stop points_per_octave`
    Oct { start: f64, stop: f64, ppo: usize },
    /// `.STEP LIST {param} v1 v2 v3 ...`
    List(Vec<f64>),
    /// `.STEP {param} start stop step`  (legacy implicit-LIN form)
    LinImplicit { start: f64, stop: f64, step: f64 },
}

/// A `.STEP` parameter sweep directive.
///
/// `target` may be either a global `.PARAM` name (modifies `.PARAM` map and
/// re-evaluates element values), or a `device.param` form like `r1.resistance`
/// which directly mutates a device parameter.
#[derive(Debug, Clone)]
pub struct StepDirective {
    /// Parameter name (e.g. `vdd`) or `device.param` form (e.g. `r1.resistance`).
    pub target: String,
    /// How to generate the sweep values.
    pub kind: StepKind,
}

impl StepDirective {
    /// Materialize the sweep into a flat `Vec<f64>` of values.
    pub fn values(&self) -> Vec<f64> {
        match &self.kind {
            StepKind::List(vs) => vs.clone(),
            StepKind::Lin { start, stop, step }
            | StepKind::LinImplicit { start, stop, step } => {
                if *step <= 0.0 || stop < start {
                    return vec![*start];
                }
                let mut out = Vec::new();
                let mut v = *start;
                // Add a tiny epsilon to handle float drift on the final step.
                let eps = step.abs() * 1e-9;
                while v <= *stop + eps {
                    out.push(v);
                    v += step;
                }
                out
            }
            StepKind::Dec { start, stop, ppd } => {
                if *start <= 0.0 || *stop <= 0.0 || *ppd == 0 {
                    return vec![*start];
                }
                let n_decades = (stop / start).log10();
                let n_points = (n_decades * *ppd as f64).ceil() as usize + 1;
                (0..n_points)
                    .map(|i| start * 10f64.powf(i as f64 / *ppd as f64))
                    .filter(|v| *v <= stop * (1.0 + 1e-12))
                    .collect()
            }
            StepKind::Oct { start, stop, ppo } => {
                if *start <= 0.0 || *stop <= 0.0 || *ppo == 0 {
                    return vec![*start];
                }
                let n_octaves = (stop / start).log2();
                let n_points = (n_octaves * *ppo as f64).ceil() as usize + 1;
                (0..n_points)
                    .map(|i| start * 2f64.powf(i as f64 / *ppo as f64))
                    .filter(|v| *v <= stop * (1.0 + 1e-12))
                    .collect()
            }
        }
    }
}

/// A user-defined function from a `.FUNC` directive.
///
/// `args` are formal parameter names; `body` is the parsed expression that
/// references them via `Expression::Param(name)`.  Resolved at expression
/// evaluation time by inlining the body with arg substitution.
#[derive(Debug, Clone)]
pub struct FuncDef {
    pub name: String,
    pub args: Vec<String>,
    pub body: Expression,
}

/// Custom statistical distribution kind for `.DISTRIBUTION` directives.
#[derive(Debug, Clone, PartialEq)]
pub enum DistKind {
    /// `UNIFORM` — flat distribution over `[-1, 1] * tolerance`.
    Uniform,
    /// `GAUSSIAN` — normal distribution with given sigma.
    Gaussian,
    /// `LOGNORM` — log-normal distribution.
    Lognorm,
    /// `BIMODAL` — mixture of two Gaussians at ±sigma.
    Bimodal,
}

/// A `.DISTRIBUTION name type [parameters]` directive.
///
/// HSPICE-compatible custom statistical distribution, referenced by
/// `DIST=distname` in `.MODEL` parameter blocks during Monte Carlo analysis.
#[derive(Debug, Clone)]
pub struct CustomDistribution {
    /// Distribution name (case-insensitive lookup key), e.g. `myunif`.
    pub name: String,
    /// Distribution kind.
    pub kind: DistKind,
    /// Optional extra parameters (sigma scale, bimodal split, etc.).
    pub params: Vec<f64>,
}

/// A reference to one `.MODEL` within a `.BINMODEL` group.
#[derive(Debug, Clone)]
pub struct BinModelEntry {
    /// The `.MODEL` name this bin entry references.
    pub model_name: String,
    /// Minimum drawn gate length [m].  `None` means no lower bound.
    pub lmin: Option<f64>,
    /// Maximum drawn gate length [m].  `None` means no upper bound.
    pub lmax: Option<f64>,
    /// Minimum drawn gate width [m].  `None` means no lower bound.
    pub wmin: Option<f64>,
    /// Maximum drawn gate width [m].  `None` means no upper bound.
    pub wmax: Option<f64>,
}

/// A `.BINMODEL name NMOS|PMOS` directive that groups multiple `.MODEL`
/// entries and auto-selects the matching bin based on drawn L/W at
/// MOSFET instantiation time.
#[derive(Debug, Clone)]
pub struct BinModel {
    /// BinModel group name, e.g. `nch`.
    pub name: String,
    /// Device type string: `"nmos"` or `"pmos"`.
    pub kind: String,
    /// Ordered list of model bins.  The first bin whose L/W window
    /// contains the drawn dimensions is selected.
    pub entries: Vec<BinModelEntry>,
}

impl BinModel {
    /// Resolve the best-matching `.MODEL` name for the given drawn dimensions.
    ///
    /// Returns the `model_name` of the first `BinModelEntry` whose
    /// `[lmin, lmax] × [wmin, wmax]` window contains `(l, w)`, or `None`
    /// if no bin matches.  Bounds that are `None` are treated as −∞ / +∞.
    pub fn resolve(&self, l: f64, w: f64) -> Option<&str> {
        self.entries
            .iter()
            .find(|e| {
                let l_ok = e.lmin.map_or(true, |lo| l >= lo)
                    && e.lmax.map_or(true, |hi| l <= hi);
                let w_ok = e.wmin.map_or(true, |lo| w >= lo)
                    && e.wmax.map_or(true, |hi| w <= hi);
                l_ok && w_ok
            })
            .map(|e| e.model_name.as_str())
    }
}

/// Output format selector for `.PRINT FILE= FORMAT=` modifiers (T.8).
///
/// Corresponds to the `FORMAT=` keyword on a `.PRINT` directive.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub enum PrintFormat {
    /// Default — inherit from global options / command-line.
    #[default]
    Default,
    /// Comma-separated values with a header row.
    Csv,
    /// Tab-separated with `#` comment lines (gnuplot-friendly).
    Gnuplot,
    /// Berkeley rawfile format (ngspice-compatible).
    Raw,
    /// HSPICE POST=2 binary probe format.
    Probe,
    /// TecPlot column format.
    Tecplot,
}

impl PrintFormat {
    /// Parse from the string after `FORMAT=` (case-insensitive).
    pub fn from_str(s: &str) -> Option<Self> {
        match s.to_ascii_uppercase().as_str() {
            "CSV" => Some(PrintFormat::Csv),
            "GNUPLOT" => Some(PrintFormat::Gnuplot),
            "RAW" => Some(PrintFormat::Raw),
            "PROBE" => Some(PrintFormat::Probe),
            "TECPLOT" => Some(PrintFormat::Tecplot),
            _ => None,
        }
    }
}

/// A `.SAVE` / `.PRINT` / `.PLOT` directive — describes which signals to record.
#[derive(Debug, Clone, PartialEq)]
pub enum SaveSpec {
    /// `V(node)` — single node voltage.
    NodeVoltage(String),
    /// `V(n1,n2)` — differential voltage.
    NodeVoltageDiff(String, String),
    /// `I(vname)` — branch current of a voltage source / inductor.
    BranchCurrent(String),
    /// `P(element)` / `W(element)` — instantaneous power dissipated by element (T.14).
    ///
    /// `W` is the Xyce spelling; both map to this variant.  Power is computed
    /// as `V_element * I_element` from the solution vector.
    Power(String),
    /// `N(node)` — noise spectral density at node (V²/Hz) from `.NOISE` analysis (T.14).
    NoiseDensity(String),
    /// `V(*)` — wildcard for all node voltages.
    AllVoltages,
    /// `I(*)` — wildcard for all branch currents.
    AllCurrents,
    /// `*` — wildcard for everything.
    All,
    /// `par('expr')` — HSPICE computed probe expression.
    ///
    /// The string contains the raw arithmetic expression extracted from
    /// the single-quoted argument of `par(...)`.  The expression may
    /// reference signals like `v(a)`, `i(R1)`, etc., and is evaluated
    /// post-simulation by the output stage.
    ComputedExpr(String),
}

/// A parsed `.SAVE` / `.PRINT` / `.PLOT` directive.
#[derive(Debug, Clone)]
pub struct SaveDirective {
    /// Which directive emitted this entry: `"save"`, `"print"`, or `"plot"`.
    pub kind: String,
    /// Optional analysis qualifier — e.g. `"tran"`, `"ac"`, `"dc"`, `"op"`,
    /// `"noise"`.  `None` means "all analyses".
    pub analysis: Option<String>,
    /// One or more output specifications.
    pub specs: Vec<SaveSpec>,
    /// `FILE="out.csv"` — redirect output to a named file instead of stdout (T.8).
    /// `None` means write to stdout (or the simulator's default output path).
    pub output_file: Option<String>,
    /// `FORMAT=CSV|GNUPLOT|RAW|PROBE|TECPLOT` — output format selector (T.8).
    pub format: PrintFormat,
    /// `DELIMITER=","` — column separator for text formats (T.8).
    /// `None` means use the format's natural default (comma for CSV, tab for
    /// GNUPLOT, space for plain text).
    pub delimiter: Option<String>,
}

/// A pending subcircuit instance (`X` element) before expansion.
#[derive(Debug, Clone)]
pub struct PendingSubcktInstance {
    /// Instance name, e.g. `xfoo`.
    pub instance_name: String,
    /// Subcircuit definition name referenced, e.g. `divider`.
    pub subckt_name: String,
    /// Node connection strings in declaration order.
    pub nodes: Vec<String>,
}

/// An HSPICE `OPTVAL(init, lower, upper)` optimization parameter.
///
/// When a `.PARAM` value is specified as `OPTVAL(init, lower, upper)`, the
/// parameter takes the `init` value for normal simulation while the bounds
/// are stored for use by an optimizer.  This is the foundation for future
/// `.OPTIMIZE` analysis support.
#[derive(Debug, Clone)]
pub struct OptimizeParam {
    /// Parameter name.
    pub name: String,
    /// Initial (current) value used in simulation.
    pub init: f64,
    /// Lower bound for optimization.
    pub lower: f64,
    /// Upper bound for optimization.
    pub upper: f64,
}

/// Intermediate representation of a parsed SPICE netlist, before conversion to a `Circuit`.
#[derive(Debug, Clone)]
pub struct ParsedNetlist {
    /// Title line (first line of the SPICE netlist).
    pub title: String,
    /// Element instance statements (R, C, L, D, M, V, I, E, G, ...).
    pub elements: Vec<ElementStatement>,
    /// `.MODEL` statements.
    pub models: Vec<ModelStatement>,
    /// Analysis commands (`.OP`, `.DC`, `.TRAN`, `.AC`, `.NOISE`).
    pub analyses: Vec<AnalysisStatement>,
    /// Global `.PARAM` definitions (name -> resolved value).
    pub params: AHashMap<String, f64>,
    /// `.SUBCKT` definitions.
    pub subcircuits: Vec<SubcircuitDef>,
    /// Pending `X` subcircuit instances to be expanded in `build_circuit`.
    pub pending_subckt_instances: Vec<PendingSubcktInstance>,
    /// `.IC v(node)=value` — initial conditions for transient analysis (node name, voltage).
    pub initial_conditions: Vec<(String, f64)>,
    /// `.NODESET v(node)=value` — solver initial-guess biases (node name, voltage).
    pub node_sets: Vec<(String, f64)>,
    /// `.GLOBAL node1 node2 ...` — nodes visible inside subcircuits without port passing.
    pub globals: Vec<String>,
    /// `.TEMP t1 [t2 ...]` — operating temperatures in Celsius (accumulated across multiple directives).
    pub temperatures: Vec<f64>,
    /// Simulation options from `.OPTIONS` directives (accumulated, later overrides earlier).
    pub options: pisim_core::SimOptions,
    /// `.MEAS` / `.MEASURE` statements (in declaration order).
    pub measures: Vec<MeasureStatement>,
    /// `.NOISE` statements (in declaration order).
    pub noise_statements: Vec<NoiseStatement>,
    /// `.DISTO` statements (in declaration order).
    pub disto_statements: Vec<DistoStatement>,
    /// `.FFT` statements (in declaration order).
    pub fft_statements: Vec<FftStatement>,
    /// `.STEP` parameter sweeps (in declaration order).
    pub steps: Vec<StepDirective>,
    /// `.FUNC` user-defined functions, keyed by lowercase name.
    pub funcs: AHashMap<String, FuncDef>,
    /// `.SAVE` / `.PRINT` / `.PLOT` output specifications.
    pub saves: Vec<SaveDirective>,
    /// Symbolic `.PARAM name = expr` definitions, parsed at directive time
    /// but lazily evaluated against `params` so forward references and
    /// dependencies on other `.PARAM`s resolve correctly.
    pub param_exprs: Vec<(String, Expression)>,
    /// `.DATA` / `.ENDDATA` tabular sweep blocks.
    pub data_blocks: Vec<DataBlock>,
    /// `.control` / `.endc` blocks captured verbatim for interpreter execution.
    pub control_blocks: Vec<ControlBlock>,
    /// `.GLOBAL_PARAM` definitions — globally visible in all subcircuit scopes
    /// without explicit port passing (Xyce semantics).
    pub global_params: AHashMap<String, f64>,
    /// `.BINMODEL` directives — MOSFET model bin groups for geometry-based
    /// model selection (T.11).
    pub bin_models: Vec<BinModel>,
    /// `.DISTRIBUTION` directives — custom statistical distribution definitions
    /// referenced by `DIST=name` in `.MODEL` parameter blocks (T.12).
    pub distributions: Vec<CustomDistribution>,
    /// `.PARAM name = OPTVAL(init, lower, upper)` optimization variable declarations.
    /// The parameter's current value is `init`; bounds are stored here for optimizers.
    pub optimize_params: Vec<OptimizeParam>,
    /// `.CONNECT net1 net2` directives (W.6) — pairs of net names to merge after build.
    pub connect_directives: Vec<(String, String)>,
    /// `.EXTRACT [TRAN|AC|DC] label=expr` entries (HSPICE W.5).
    pub extract_specs: Vec<ExtractSpec>,
}

impl ParsedNetlist {
    pub fn new() -> Self {
        Self {
            title: String::new(),
            elements: Vec::new(),
            models: Vec::new(),
            analyses: Vec::new(),
            params: AHashMap::new(),
            subcircuits: Vec::new(),
            pending_subckt_instances: Vec::new(),
            initial_conditions: Vec::new(),
            node_sets: Vec::new(),
            globals: Vec::new(),
            temperatures: Vec::new(),
            options: pisim_core::SimOptions::default(),
            measures: Vec::new(),
            noise_statements: Vec::new(),
            disto_statements: Vec::new(),
            fft_statements: Vec::new(),
            steps: Vec::new(),
            funcs: AHashMap::new(),
            saves: Vec::new(),
            param_exprs: Vec::new(),
            data_blocks: Vec::new(),
            control_blocks: Vec::new(),
            global_params: AHashMap::new(),
            bin_models: Vec::new(),
            distributions: Vec::new(),
            optimize_params: Vec::new(),
            connect_directives: Vec::new(),
            extract_specs: Vec::new(),
        }
    }
}

impl Default for ParsedNetlist {
    fn default() -> Self {
        Self::new()
    }
}

/// A single element instance line, e.g. `R1 1 2 1k` or `M1 d g s b NMOD W=10u L=1u`.
#[derive(Debug, Clone)]
pub struct ElementStatement {
    /// Instance name, e.g. `r1`, `m1`, `v1`.
    pub name: String,
    /// The device kind determined from the first letter.
    pub kind: DeviceKind,
    /// Node connection names (strings, not yet resolved to NodeIds).
    pub nodes: Vec<String>,
    /// Primary value (resistance, capacitance, DC voltage, etc.) if given as bare number.
    pub value: Option<f64>,
    /// Model name reference, if applicable (for D, M, Q devices).
    pub model_name: Option<String>,
    /// Key-value parameter pairs (e.g. `W=10u`, `L=1u`).
    pub params: Vec<(String, f64)>,
}

/// A `.MODEL` statement.
#[derive(Debug, Clone)]
pub struct ModelStatement {
    /// Model name, e.g. `nmod`.
    pub name: String,
    /// Model type string, e.g. `nmos`, `pmos`, `d`, `npn`.
    pub kind: String,
    /// Model parameters.
    pub params: Vec<(String, f64)>,
}

/// An analysis command statement.
#[derive(Debug, Clone)]
pub struct AnalysisStatement {
    /// Which analysis type.
    pub kind: AnalysisKind,
    /// Analysis parameters (varies by kind).
    pub params: Vec<(String, f64)>,
}

/// Output specifier for a `.SENS` statement.
///
/// Mirrors `pisim_analysis::SensOutput` but lives in the parser crate to
/// avoid a parser → analysis crate dependency.
#[derive(Debug, Clone, PartialEq)]
pub enum SensOutputSpec {
    /// `V(node)` — a node voltage.
    NodeVoltage(String),
    /// `I(vname)` — branch current of a voltage source.
    BranchCurrent(String),
}

/// Supported analysis types.
#[derive(Debug, Clone, PartialEq)]
pub enum AnalysisKind {
    /// `.OP` — DC operating point.
    DcOp,
    /// `.DC` — DC sweep.
    DcSweep,
    /// `.TRAN` — transient analysis.
    Tran,
    /// `.AC` — AC small-signal analysis.
    Ac,
    /// `.NOISE` — noise analysis.
    Noise,
    /// `.FOUR f0 v(node)...` — Fourier decomposition of transient result.
    Four,
    /// `.FFT` — FFT analysis (stub; deferred to Phase 3.4 full windowed FFT).
    Fft,
    /// `.SENS output [param1 param2 ...]` — DC sensitivity analysis.
    Sens {
        /// The output variable to differentiate.
        output: SensOutputSpec,
        /// Device names whose primary parameter is perturbed.
        params: Vec<String>,
    },
    /// `.HB f1 [f2] nharmonics` — Harmonic Balance (Phase 3.7).
    ///
    /// Single-tone form (`.HB f1 nharmonics`) and two-tone form
    /// (`.HB f1 f2 nharmonics`) are distinguished by the number of
    /// numeric arguments. The parser stores the parsed values in
    /// `AnalysisStatement.params` keyed by `f1`, `f2` (optional), and
    /// `nharmonics` so the analysis dispatcher can pick the right runner.
    Hb,
    /// `.DISTO f1 numf2 f2overf1 [fstart] [fstop]` — Volterra distortion.
    Disto,
}

/// A `.SUBCKT` definition.
#[derive(Debug, Clone)]
pub struct SubcircuitDef {
    /// Subcircuit name.
    pub name: String,
    /// Port (interface) node names.
    pub ports: Vec<String>,
    /// Default parameter values declared on the `.SUBCKT` header line,
    /// e.g. `.SUBCKT inv in out PARAMS: W=1u L=100n`.
    pub default_params: Vec<(String, f64)>,
    /// Element statements inside the subcircuit body.
    pub body: Vec<ElementStatement>,
    /// `X` subcircuit instances found in the body (not yet expanded).
    pub nested_instances: Vec<PendingSubcktInstance>,
}

// ---------------------------------------------------------------------------
// .control / .endc block types
// ---------------------------------------------------------------------------

/// A single statement inside a `.control` / `.endc` block.
///
/// Lines are stored as raw trimmed strings; the interpreter in
/// `pisim_analysis::control` handles evaluation.
#[derive(Debug, Clone, PartialEq)]
pub struct ControlStatement {
    /// The raw text of the statement (trimmed, original case preserved).
    pub raw: String,
}

/// A `.control` / `.endc` block captured verbatim from the netlist.
///
/// PiSIM captures these blocks at parse time and defers execution to
/// `pisim_analysis::control::ControlInterpreter`.
#[derive(Debug, Clone, Default)]
pub struct ControlBlock {
    /// Lines collected between `.control` and `.endc` (exclusive).
    pub lines: Vec<ControlStatement>,
}

/// A `.DATA` / `.ENDDATA` tabular sweep block.
///
/// ```spice
/// .DATA datname param1 param2
/// val1a val1b
/// val2a val2b
/// .ENDDATA
/// ```
#[derive(Debug, Clone)]
pub struct DataBlock {
    /// Data block name (used to reference from `.STEP DATA datname`).
    pub name: String,
    /// Parameter names (column headers).
    pub params: Vec<String>,
    /// Row data — each row has one value per parameter.
    pub rows: Vec<Vec<f64>>,
}

/// A polynomial-controlled source (POLY form for E/G/F/H elements).
///
/// `E n+ n- POLY(1) (v1+ v1-) c0 c1 c2 ...`
#[derive(Debug, Clone)]
pub struct PolySource {
    /// Polynomial degree (the `n` in `POLY(n)`).
    pub degree: usize,
    /// Controlling node-pairs `(n+, n-)` — one pair per dimension.
    pub control_pairs: Vec<(String, String)>,
    /// Polynomial coefficients `[c0, c1, c2, ...]`.
    pub coefficients: Vec<f64>,
}

/// Discriminates the kind of a controlled-source element (E/G/F/H).
#[derive(Debug, Clone)]
pub enum SourceKind {
    /// Standard linear form with a single gain value.
    Linear(f64),
    /// POLY(n) polynomial form.
    Poly(PolySource),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parsed_netlist_default() {
        let nl = ParsedNetlist::new();
        assert!(nl.title.is_empty());
        assert!(nl.elements.is_empty());
        assert!(nl.models.is_empty());
        assert!(nl.analyses.is_empty());
        assert!(nl.params.is_empty());
        assert!(nl.subcircuits.is_empty());
    }

    #[test]
    fn element_statement_construction() {
        let elem = ElementStatement {
            name: "r1".into(),
            kind: DeviceKind::Resistor,
            nodes: vec!["1".into(), "2".into()],
            value: Some(1e3),
            model_name: None,
            params: vec![],
        };
        assert_eq!(elem.name, "r1");
        assert_eq!(elem.kind, DeviceKind::Resistor);
        assert_eq!(elem.nodes.len(), 2);
        assert_eq!(elem.value, Some(1e3));
    }

    #[test]
    fn model_statement_construction() {
        let model = ModelStatement {
            name: "nmod".into(),
            kind: "nmos".into(),
            params: vec![("vth0".into(), 0.5), ("kp".into(), 120e-6)],
        };
        assert_eq!(model.name, "nmod");
        assert_eq!(model.kind, "nmos");
        assert_eq!(model.params.len(), 2);
    }

    #[test]
    fn analysis_statement_construction() {
        let analysis = AnalysisStatement {
            kind: AnalysisKind::Tran,
            params: vec![("tstep".into(), 1e-9), ("tstop".into(), 1e-6)],
        };
        assert_eq!(analysis.kind, AnalysisKind::Tran);
        assert_eq!(analysis.params.len(), 2);
    }

    #[test]
    fn subcircuit_def_construction() {
        let sub = SubcircuitDef {
            name: "inv".into(),
            ports: vec!["in".into(), "out".into(), "vdd".into(), "vss".into()],
            default_params: vec![],
            body: vec![],
            nested_instances: vec![],
        };
        assert_eq!(sub.name, "inv");
        assert_eq!(sub.ports.len(), 4);
        assert!(sub.body.is_empty());
    }

    #[test]
    fn analysis_kind_equality() {
        assert_eq!(AnalysisKind::DcOp, AnalysisKind::DcOp);
        assert_ne!(AnalysisKind::DcOp, AnalysisKind::Tran);
        assert_ne!(AnalysisKind::Ac, AnalysisKind::DcSweep);
    }

    #[test]
    fn parsed_netlist_with_data() {
        let mut nl = ParsedNetlist::new();
        nl.title = "Test circuit".into();
        nl.params.insert("vdd".into(), 3.3);
        nl.elements.push(ElementStatement {
            name: "r1".into(),
            kind: DeviceKind::Resistor,
            nodes: vec!["1".into(), "0".into()],
            value: Some(1e3),
            model_name: None,
            params: vec![],
        });
        nl.analyses.push(AnalysisStatement {
            kind: AnalysisKind::DcOp,
            params: vec![],
        });
        assert_eq!(nl.title, "Test circuit");
        assert_eq!(nl.params.get("vdd"), Some(&3.3));
        assert_eq!(nl.elements.len(), 1);
        assert_eq!(nl.analyses.len(), 1);
    }
}
