//! SPICE netlist parser — Zig-compiler-style tokenizer + recursive descent.
//!
//! Design follows Zig's tokenizer/parser pattern:
//!   - Tokenizer is a struct with `next()` that yields Token
//!   - Zero-copy: tokens reference source bytes via spans
//!   - StaticStringMap for O(1) keyword/directive lookup
//!   - Expression parser: recursive descent with Pratt-style precedence
//!
//! Public API: `SpiceParser::parse_bytes(&[u8]) -> Result<ParsedNetlist>`

pub mod expr;
pub mod static_map;
pub mod tokenizer;

use incspice_core::{
    AcStimulus, Circuit, DeviceId, DeviceInstance, DeviceKind, ExprEval, ModelKind, NodeId,
    ParamMap, SubcktCall, SubcktDef, topo_sort_params,
};
use std::cell::RefCell;
use std::path::{Path, PathBuf};
use thiserror::Error;

thread_local! {
    static INCLUDE_DIR_STACK: RefCell<Vec<PathBuf>> = const { RefCell::new(Vec::new()) };
}

#[derive(Debug, Error)]
pub enum ParseError {
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
    #[error("line {line}: {msg}")]
    Syntax { line: usize, msg: String },
    #[error("subcircuit cycle: {0}")]
    SubcircuitCycle(String),
}

// ---------------------------------------------------------------------------
// Analysis kinds — public flat API (used by SpiceParser::parse_file /
// parse_bytes which return the (Circuit, Vec<AnalysisStatement>, SimOptions)
// tuple consumed by test_external and downstream runners).
// ---------------------------------------------------------------------------

/// Flat analysis kind tag used in the public `AnalysisStatement` API.
#[derive(Debug, Clone, PartialEq)]
pub enum AnalysisKind {
    DcOp,
    DcSweep,
    Tran,
    Ac,
    Hb,
    Pss,
    Sens,
    Mc,
    Noise,
    Pz,
    Tf,
    Sp,
}

/// A single analysis directive extracted from the netlist.
///
/// Parameters are encoded as `(key, value)` pairs in `params`.  The encoding
/// conventions are documented in the `SpiceParser` section of the crate docs.
#[derive(Debug, Clone)]
pub struct AnalysisStatement {
    pub kind: AnalysisKind,
    pub params: Vec<(String, f64)>,
}

/// Simulation options returned by the public tuple API.
///
/// Defaults: `temp = 27.0`, `tnom = 27.0`, `gmin = 1e-12`.
#[derive(Debug, Clone)]
pub struct SimOptions {
    /// Operating temperature in degrees Celsius.
    pub temp: f64,
    /// Nominal temperature in degrees Celsius.
    pub tnom: f64,
    /// Minimum conductance (gmin).
    pub gmin: f64,
    /// Pseudo-transient continuation maximum time [s].
    /// When > 0.0, enables PTC as a convergence fallback for DC OP.
    pub ptranmax: f64,
}

impl Default for SimOptions {
    fn default() -> Self {
        Self {
            temp: 27.0,
            tnom: 27.0,
            gmin: 1e-12,
            ptranmax: 0.0,
        }
    }
}

// ---------------------------------------------------------------------------
// Internal analysis kinds — used by ParsedNetlist (legacy rich API).
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub enum AcSweepType {
    Lin(usize),
    Dec(usize),
    Oct(usize),
}

#[derive(Debug, Clone)]
pub enum InternalAnalysisKind {
    DcOp,
    DcSweep {
        source: String,
        start: f64,
        stop: f64,
        step: f64,
        /// Optional second sweep (nested `.DC src1 ... src2 ...` form).
        source2: Option<String>,
        start2: f64,
        stop2: f64,
        step2: f64,
    },
    Ac {
        sweep: AcSweepType,
        fstart: f64,
        fstop: f64,
    },
    Transient {
        tstep: f64,
        tstop: f64,
        tstart: f64,
        uic: bool,
    },
    Noise {
        output: String,
        source: String,
        sweep: AcSweepType,
        fstart: f64,
        fstop: f64,
        npoints: usize,
    },
    /// `.HB` — harmonic balance (alias: `Hb`)
    HarmonicBalance {
        fundamental: f64,
        harmonics: usize,
    },
    /// Kept for backward compat — same as `HarmonicBalance`.
    Hb {
        fundamental: f64,
        harmonics: usize,
    },
    Pss {
        fundamental: f64,
    },
    /// `.SP` — S-parameter analysis.
    SParam {
        num_ports: usize,
        sweep: AcSweepType,
        fstart: f64,
        fstop: f64,
    },
    /// Kept for backward compat — same as `SParam`.
    Sp {
        num_ports: usize,
        sweep: AcSweepType,
        fstart: f64,
        fstop: f64,
    },
    /// `.MC` — Monte Carlo.
    MonteCarlo {
        num_samples: usize,
    },
    /// Kept for backward compat — same as `MonteCarlo`.
    Mc {
        num_samples: usize,
    },
    Sensitivity {
        output: String,
    },
    /// `.FOUR` — Fourier analysis.
    Fourier {
        fundamental: f64,
        variables: Vec<String>,
    },
    /// `.FFT` — FFT spectrum analysis.
    Fft {
        npoints: usize,
        variables: Vec<String>,
    },
    /// `.PZ` — pole-zero analysis.
    PoleZero {
        input: String,
        output: String,
    },
    /// `.TF` — transfer function.
    TransferFunction {
        output: String,
        input: String,
    },
    /// `.WCASE` — worst-case corner analysis.
    WorstCase {
        k_sigma: f64,
    },
    /// `.ENVLP` — envelope following analysis.
    Envelope {
        fund: f64,
        tstop: f64,
        tstep: f64,
    },
    /// `.ALTER` block.
    Alter {
        params: Vec<(String, String, f64)>,
    },
    /// `.IF` conditional (resolved at parse time; may be emitted as artefact).
    If {
        condition: String,
    },
}

/// Internal simulation options (rich, as parsed from `.OPTIONS`).
#[derive(Debug, Clone, Default)]
pub struct ParseOptions {
    pub reltol: Option<f64>,
    pub abstol: Option<f64>,
    pub vntol: Option<f64>,
    pub gmin: Option<f64>,
    pub method: Option<String>,
    pub maxord: Option<usize>,
    /// Any unrecognised `.OPTIONS key=value` pairs, keyed by lowercase name.
    pub extras: std::collections::HashMap<String, f64>,
}

#[derive(Debug)]
pub struct ParsedNetlist {
    pub circuit: Circuit,
    pub analyses: Vec<InternalAnalysisKind>,
    pub options: ParseOptions,
}

// ---------------------------------------------------------------------------
// AC stimulus registration
// ---------------------------------------------------------------------------

/// Walk all devices that have an `ac_mag` parameter and register the
/// corresponding `AcStimulus` entries on the circuit.
///
/// Must be called **after** `circuit.build_topology()` so that every voltage
/// source already has its `branch_index` assigned.
///
/// For a voltage source `V name n+ n- AC mag [phase]`:
///   - The MNA branch-equation row is `num_vars + branch_index`.
///   - The AC stimulus is a complex phasor: `re = mag*cos(phase_rad)`,
///     `im = mag*sin(phase_rad)`.
///
/// For a current source `I name n+ n- AC mag [phase]`:
///   - Positive KCL injection at the `n+` MNA node row.
///   - Negative KCL injection at the `n-` MNA node row (if not ground).
fn register_ac_stimuli(circuit: &mut Circuit) {
    let num_vars = circuit.num_vars() as usize;

    // Collect stimuli first to avoid borrowing issues.
    let mut stimuli: Vec<AcStimulus> = Vec::new();

    for device in circuit.devices() {
        let ac_mag = match device.params.get("ac_mag") {
            Some(v) if v != 0.0 => v,
            _ => continue, // no AC excitation on this device
        };
        let ac_phase_deg = device.params.get("ac_phase").unwrap_or(0.0);
        let ac_phase_rad = ac_phase_deg * std::f64::consts::PI / 180.0;
        let re = ac_mag * ac_phase_rad.cos();
        let im = ac_mag * ac_phase_rad.sin();

        match device.kind {
            DeviceKind::VoltageSource | DeviceKind::BsourceV | DeviceKind::Vcvs | DeviceKind::Ccvs => {
                // Voltage source KVL branch row = num_vars + branch_index.
                if let Some(bi) = device.branch_index {
                    let branch_row = num_vars + bi as usize;
                    stimuli.push(AcStimulus::VoltageSource(branch_row, re, im));
                }
            }
            DeviceKind::CurrentSource | DeviceKind::BsourceI | DeviceKind::Vccs | DeviceKind::Cccs => {
                // Current source: inject at n+ KCL row, withdraw at n- KCL row.
                let pos_node = device.terminals.get(0).map(|t| t.node);
                let neg_node = device.terminals.get(1).map(|t| t.node);

                let pos_row = pos_node
                    .filter(|n| !n.is_ground())
                    .map(|n| (n.0 - 1) as usize);
                let neg_row = neg_node
                    .filter(|n| !n.is_ground())
                    .map(|n| (n.0 - 1) as usize);

                // AcStimulus::CurrentSource requires a valid (non-ground) pos row.
                // If n+ is ground but n- is not, negate and swap so that the
                // non-ground node is used as the effective "pos" (inverted sign).
                // If both are ground, skip (degenerate case).
                match (pos_row, neg_row) {
                    (Some(p), neg) => {
                        stimuli.push(AcStimulus::CurrentSource(p, neg, re, im));
                    }
                    (None, Some(n)) => {
                        // n+ is ground → negate stimulus and treat n- as pos.
                        stimuli.push(AcStimulus::CurrentSource(n, None, -re, -im));
                    }
                    (None, None) => {} // both ground, skip
                }
            }
            _ => {}
        }
    }

    for stim in stimuli {
        circuit.add_ac_stimulus(stim);
    }
}

// ---------------------------------------------------------------------------
// SpiceParser — entry point
// ---------------------------------------------------------------------------

pub struct SpiceParser;

impl SpiceParser {
    /// Public tuple API: parse a `.sp` file and return `(Circuit,
    /// Vec<AnalysisStatement>, SimOptions)`.
    ///
    /// This is the primary entry point used by external runners and
    /// `test_external`.
    pub fn parse_file(
        path: &Path,
    ) -> Result<(Circuit, Vec<AnalysisStatement>, SimOptions), ParseError> {
        let contents = std::fs::read(path)?;
        Self::with_include_dir(path.parent(), || Self::parse_bytes(&contents))
    }

    fn with_include_dir<T>(dir: Option<&Path>, f: impl FnOnce() -> T) -> T {
        if let Some(dir) = dir {
            INCLUDE_DIR_STACK.with(|stack| stack.borrow_mut().push(dir.to_path_buf()));
            let result = f();
            INCLUDE_DIR_STACK.with(|stack| {
                stack.borrow_mut().pop();
            });
            result
        } else {
            f()
        }
    }

    fn resolve_include_path(path_str: &str) -> PathBuf {
        let path = PathBuf::from(path_str);
        if path.is_absolute() {
            return path;
        }

        INCLUDE_DIR_STACK.with(|stack| {
            stack
                .borrow()
                .last()
                .map(|dir| dir.join(&path))
                .unwrap_or(path)
        })
    }

    /// Public tuple API: parse raw SPICE bytes and return `(Circuit,
    /// Vec<AnalysisStatement>, SimOptions)`.
    pub fn parse_bytes(
        input: &[u8],
    ) -> Result<(Circuit, Vec<AnalysisStatement>, SimOptions), ParseError> {
        let netlist = Self::parse_netlist(input)?;
        let sim_opts = SimOptions {
            temp: netlist
                .options
                .extras
                .get("temp")
                .copied()
                .unwrap_or(27.0),
            tnom: netlist
                .options
                .extras
                .get("tnom")
                .copied()
                .unwrap_or(27.0),
            gmin: netlist.options.gmin.unwrap_or(1e-12),
            ptranmax: netlist
                .options
                .extras
                .get("ptranmax")
                .copied()
                // Xyce-style: `.OPTIONS PSEUDOTRANSIENT=1` enables PTC with a default time.
                .or_else(|| netlist.options.extras.get("pseudotransient").copied().filter(|&v| v > 0.0).map(|_| 1e-6))
                .unwrap_or(0.0),
        };
        let analyses = internal_to_statements(&netlist.analyses);
        Ok((netlist.circuit, analyses, sim_opts))
    }

    /// Internal rich API: parse bytes and return a `ParsedNetlist`.
    ///
    /// Used by `parse_str` (which the existing unit tests call) and internally
    /// by `parse_bytes` above.
    pub fn parse_netlist(input: &[u8]) -> Result<ParsedNetlist, ParseError> {
        let mut tok = tokenizer::Tokenizer::new(input);
        let mut circuit = Circuit::new();
        let mut analyses: Vec<InternalAnalysisKind> = Vec::new();
        let mut options = ParseOptions::default();

        // TODO (DOD §string-interner): When node terminal parsing is implemented,
        // replace HashMap<String, NodeId> with string_interner::StringInterner for
        // the internal node-name → NodeId lookup table.  The public API (Circuit)
        // does not change; the interner is purely local to this function.
        // Example:
        //   let mut node_interner = string_interner::StringInterner::default();
        //   // intern name → symbol, map symbol → NodeId

        // Skip title line
        tok.skip_line();

        // Pending model associations: (DeviceId, model_name_lowercase, line_number).
        // Populated while parsing M/Q/D element lines; applied after full parse
        // so that forward-declared .MODEL directives are visible.
        let mut pending_models: Vec<(DeviceId, String, usize)> = Vec::new();

        // Pending K-element (mutual inductance) couplings: (l1_name, l2_name, k).
        // Resolved after all elements are parsed so forward-declared inductors work.
        let mut pending_k_elements: Vec<(String, String, f64)> = Vec::new();

        // Raw .PARAM definitions collected during parsing.
        // Each entry is (name_lowercase, raw_expr_string).
        // Plain numeric values are stored as their decimal string; expression
        // values (written as `{expr}`) are stored with the braces included.
        // After the parse loop all entries are evaluated in topological order
        // and stored in circuit.global_params.
        let mut raw_params: Vec<(String, String)> = Vec::new();
        let mut func_defs: Vec<(String, Vec<String>, String)> = Vec::new();
        let mut pending_device_exprs: Vec<(String, String, String)> = Vec::new();

        while tok.peek() != tokenizer::TokenKind::Eof {
            match tok.peek() {
                tokenizer::TokenKind::Dot => {
                    let directive = tok.consume_directive();
                    parse_directive(
                        &directive,
                        &mut tok,
                        &mut circuit,
                        &mut analyses,
                        &mut options,
                        &mut raw_params,
                        &mut func_defs,
                    )?;
                }
                tokenizer::TokenKind::Word => {
                    parse_element(&mut tok, &mut circuit, &mut pending_models, &mut pending_k_elements, &mut pending_device_exprs)?;
                }
                tokenizer::TokenKind::Newline | tokenizer::TokenKind::Comment => {
                    tok.advance();
                }
                _ => {
                    tok.advance();
                }
            }
        }

        // Post-parse: merge .MODEL params into devices and fix device kinds.
        merge_model_params(&mut circuit, &pending_models)?;

        // Warn about orphan models (defined but not referenced by any device).
        {
            let referenced: std::collections::HashSet<&str> = pending_models
                .iter()
                .map(|(_, name, _)| name.as_str())
                .collect();
            for model_name in circuit.models.keys() {
                if !referenced.contains(model_name.as_str()) {
                    eprintln!(
                        "warning: model '{}' defined but not referenced by any device",
                        model_name
                    );
                }
            }
        }

        // Post-parse: resolve K-element mutual inductance couplings.
        for (l1_name, l2_name, k) in &pending_k_elements {
            let l1_id = circuit.find_device_id(l1_name).ok_or_else(|| ParseError::Syntax {
                line: 0,
                msg: format!("K-element: inductor '{l1_name}' not found"),
            })?;
            let l2_id = circuit.find_device_id(l2_name).ok_or_else(|| ParseError::Syntax {
                line: 0,
                msg: format!("K-element: inductor '{l2_name}' not found"),
            })?;
            circuit.add_mutual_coupling(l1_id, l2_id, *k);
        }

        // Evaluate .PARAM expressions in topological order and store results.
        evaluate_raw_params(&raw_params, &func_defs, &mut circuit).map_err(|e| ParseError::Syntax {
            line: 0,
            msg: format!(".PARAM evaluation error: {e}"),
        })?;

        // Resolve deferred device parameter expressions now that global_params are available.
        if !pending_device_exprs.is_empty() {
            let mut eval = ExprEval::new();
            for (k, v) in &circuit.global_params {
                eval.set_var(k, *v);
            }
            for (name, params, body) in &func_defs {
                eval.set_user_func(name, params.clone(), body.clone());
            }
            for (dev_name, param_key, expr) in &pending_device_exprs {
                if let Ok(value) = eval.eval(expr) {
                    if let Some(dev) = circuit.find_device_mut(dev_name) {
                        dev.params.set(param_key, value);
                    }
                }
            }
        }

        // Flatten all X-instance calls (subcircuit expansion).
        flatten_subcircuits(&mut circuit).map_err(|e| ParseError::Syntax {
            line: 0,
            msg: format!("subcircuit flattening error: {e}"),
        })?;

        // Expand BJT extrinsic resistances (RB, RC, RE) into explicit circuit
        // elements so the intrinsic GP core evaluates at internal node voltages.
        // Must happen AFTER flatten so subcircuit BJTs are also processed.
        expand_bjt_extrinsic(&mut circuit);

        circuit.build_topology();

        // Register AC stimuli from devices that have an `ac_mag` parameter.
        // This must happen after `build_topology()` so that `branch_index` is
        // assigned for voltage sources, and after `flatten_subcircuits` so that
        // expanded sub-circuit devices are included.
        register_ac_stimuli(&mut circuit);

        // Count port-bearing voltage sources and update SP analysis num_ports.
        let num_ports = circuit.devices().iter()
            .filter(|d| d.kind == DeviceKind::VoltageSource && d.params.get("portnum").is_some())
            .count();
        for a in &mut analyses {
            match a {
                InternalAnalysisKind::SParam { num_ports: np, .. }
                | InternalAnalysisKind::Sp { num_ports: np, .. } => {
                    *np = num_ports;
                }
                _ => {}
            }
        }

        Ok(ParsedNetlist {
            circuit,
            analyses,
            options,
        })
    }

    /// Parse a SPICE string and return a `ParsedNetlist`.
    ///
    /// Primarily used by the internal unit-test suite (`tests` module).
    pub fn parse_str(input: &str) -> Result<ParsedNetlist, ParseError> {
        Self::parse_netlist(input.as_bytes())
    }
}

// ---------------------------------------------------------------------------
// Conversion: InternalAnalysisKind → AnalysisStatement
// ---------------------------------------------------------------------------

/// Convert internal rich analysis representations to the flat public API.
fn internal_to_statements(internal: &[InternalAnalysisKind]) -> Vec<AnalysisStatement> {
    let mut out = Vec::with_capacity(internal.len());

    for kind in internal {
        match kind {
            InternalAnalysisKind::DcOp => {
                out.push(AnalysisStatement {
                    kind: AnalysisKind::DcOp,
                    params: vec![],
                });
            }

            InternalAnalysisKind::DcSweep {
                source,
                start,
                stop,
                step,
                source2,
                start2,
                stop2,
                step2,
            } => {
                let mut params = vec![
                    (format!("__dc_src__{}", source), 0.0),
                    ("start".into(), *start),
                    ("stop".into(), *stop),
                    ("step".into(), *step),
                ];
                if let Some(src2) = source2 {
                    params.push((format!("__dc_src2__{}", src2), 0.0));
                    params.push(("start2".into(), *start2));
                    params.push(("stop2".into(), *stop2));
                    params.push(("step2".into(), *step2));
                }
                out.push(AnalysisStatement {
                    kind: AnalysisKind::DcSweep,
                    params,
                });
            }

            InternalAnalysisKind::Transient { tstep, tstop, uic, .. } => {
                out.push(AnalysisStatement {
                    kind: AnalysisKind::Tran,
                    params: vec![
                        ("tstep".into(), *tstep),
                        ("tstop".into(), *tstop),
                        ("uic".into(), if *uic { 1.0 } else { 0.0 }),
                    ],
                });
            }

            InternalAnalysisKind::Ac { sweep, fstart, fstop } => {
                let (sweep_type_val, npoints) = match sweep {
                    AcSweepType::Lin(n) => (0.0, *n as f64),
                    AcSweepType::Dec(n) => (1.0, *n as f64),
                    AcSweepType::Oct(n) => (2.0, *n as f64),
                };
                out.push(AnalysisStatement {
                    kind: AnalysisKind::Ac,
                    params: vec![
                        ("sweep_type".into(), sweep_type_val),
                        ("npoints".into(), npoints),
                        ("fstart".into(), *fstart),
                        ("fstop".into(), *fstop),
                    ],
                });
            }

            InternalAnalysisKind::Noise { output, source, sweep, fstart, fstop, npoints: _ } => {
                let (sweep_type_val, npoints_f) = match sweep {
                    AcSweepType::Lin(n) => (0.0, *n as f64),
                    AcSweepType::Dec(n) => (1.0, *n as f64),
                    AcSweepType::Oct(n) => (2.0, *n as f64),
                };
                out.push(AnalysisStatement {
                    kind: AnalysisKind::Noise,
                    params: vec![
                        (format!("__noise_out__{}", output), 0.0),
                        (format!("__noise_src__{}", source), 0.0),
                        ("sweep_type".into(), sweep_type_val),
                        ("fstart".into(), *fstart),
                        ("fstop".into(), *fstop),
                        ("npoints".into(), npoints_f),
                    ],
                });
            }

            InternalAnalysisKind::HarmonicBalance { fundamental, harmonics }
            | InternalAnalysisKind::Hb { fundamental, harmonics } => {
                out.push(AnalysisStatement {
                    kind: AnalysisKind::Hb,
                    params: vec![
                        ("fundamental".into(), *fundamental),
                        ("harmonics".into(), *harmonics as f64),
                    ],
                });
            }

            InternalAnalysisKind::Pss { fundamental } => {
                out.push(AnalysisStatement {
                    kind: AnalysisKind::Pss,
                    params: vec![("fundamental".into(), *fundamental)],
                });
            }

            InternalAnalysisKind::SParam { num_ports, sweep, fstart, fstop }
            | InternalAnalysisKind::Sp { num_ports, sweep, fstart, fstop } => {
                let npoints = match sweep {
                    AcSweepType::Lin(n) | AcSweepType::Dec(n) | AcSweepType::Oct(n) => *n,
                };
                let sweep_type_str = match sweep {
                    AcSweepType::Lin(_) => "lin",
                    AcSweepType::Dec(_) => "dec",
                    AcSweepType::Oct(_) => "oct",
                };
                out.push(AnalysisStatement {
                    kind: AnalysisKind::Sp,
                    params: vec![
                        ("num_ports".into(), *num_ports as f64),
                        ("npoints".into(), npoints as f64),
                        ("fstart".into(), *fstart),
                        ("fstop".into(), *fstop),
                        (format!("__sp_sweep__{}", sweep_type_str), 1.0),
                    ],
                });
            }

            InternalAnalysisKind::MonteCarlo { num_samples }
            | InternalAnalysisKind::Mc { num_samples } => {
                out.push(AnalysisStatement {
                    kind: AnalysisKind::Mc,
                    params: vec![("num_samples".into(), *num_samples as f64)],
                });
            }

            InternalAnalysisKind::Sensitivity { .. } => {
                out.push(AnalysisStatement {
                    kind: AnalysisKind::Sens,
                    params: vec![],
                });
            }

            InternalAnalysisKind::PoleZero { .. } => {
                out.push(AnalysisStatement {
                    kind: AnalysisKind::Pz,
                    params: vec![],
                });
            }

            InternalAnalysisKind::TransferFunction { .. } => {
                out.push(AnalysisStatement {
                    kind: AnalysisKind::Tf,
                    params: vec![],
                });
            }

            // Remaining internal kinds that have no flat counterpart are
            // silently dropped from the public AnalysisStatement list.
            _ => {}
        }
    }

    out
}

// ---------------------------------------------------------------------------
// Directive/element parse stubs
// ---------------------------------------------------------------------------

fn parse_directive(
    directive: &str,
    tok: &mut tokenizer::Tokenizer<'_>,
    circuit: &mut Circuit,
    analyses: &mut Vec<InternalAnalysisKind>,
    options: &mut ParseOptions,
    raw_params: &mut Vec<(String, String)>,
    func_defs: &mut Vec<(String, Vec<String>, String)>,
) -> Result<(), ParseError> {
    // Use StaticStringMap for O(1) directive dispatch
    match static_map::DIRECTIVES.get(directive) {
        Some(static_map::Directive::Op) => {
            analyses.push(InternalAnalysisKind::DcOp);
            tok.skip_line();
        }

        // ── .DC source_name start stop step ────────────────────────────────
        Some(static_map::Directive::Dc) => {
            let source = if tok.peek() == tokenizer::TokenKind::Word {
                tok.consume_word()
            } else {
                tok.skip_line();
                analyses.push(InternalAnalysisKind::DcSweep {
                    source: String::new(),
                    start: 0.0,
                    stop: 0.0,
                    step: 0.0,
                    source2: None,
                    start2: 0.0,
                    stop2: 0.0,
                    step2: 0.0,
                });
                return Ok(());
            };
            let start = parse_si_value(tok);
            let stop  = parse_si_value(tok);
            let step  = parse_si_value(tok);
            // Check for optional nested second sweep: src2 start2 stop2 step2
            let (source2, start2, stop2, step2) = if tok.peek() == tokenizer::TokenKind::Word {
                let src2 = tok.consume_word();
                let st2 = parse_si_value(tok);
                let sp2 = parse_si_value(tok);
                let sk2 = parse_si_value(tok);
                (Some(src2), st2, sp2, sk2)
            } else {
                (None, 0.0, 0.0, 0.0)
            };
            tok.skip_line();
            analyses.push(InternalAnalysisKind::DcSweep {
                source, start, stop, step,
                source2, start2, stop2, step2,
            });
        }

        // ── .AC DEC|OCT|LIN npoints fstart fstop ───────────────────────────
        Some(static_map::Directive::Ac) => {
            let sweep_type_str = if tok.peek() == tokenizer::TokenKind::Word {
                tok.consume_word().to_ascii_uppercase()
            } else {
                tok.skip_line();
                analyses.push(InternalAnalysisKind::Ac {
                    sweep: AcSweepType::Dec(10),
                    fstart: 1.0,
                    fstop: 1e9,
                });
                return Ok(());
            };
            // npoints: may be a Number token
            let npoints = match tok.peek() {
                tokenizer::TokenKind::Number => tok.consume_number() as usize,
                tokenizer::TokenKind::Word => {
                    let w = tok.consume_word();
                    parse_word_as_value(&w) as usize
                }
                _ => 10,
            };
            let fstart = parse_si_value(tok);
            let fstop  = parse_si_value(tok);
            tok.skip_line();
            let sweep = match sweep_type_str.as_str() {
                "LIN" => AcSweepType::Lin(npoints),
                "OCT" => AcSweepType::Oct(npoints),
                _     => AcSweepType::Dec(npoints), // default DEC
            };
            analyses.push(InternalAnalysisKind::Ac { sweep, fstart, fstop });
        }

        // ── .TRAN tstep tstop [tstart [tmax]] [UIC] ────────────────────────
        Some(static_map::Directive::Tran) => {
            let tstep = parse_si_value(tok);
            let tstop = parse_si_value(tok);
            // Optional tstart / tmax / UIC
            let mut tstart = 0.0;
            let mut uic = false;
            match tok.peek() {
                tokenizer::TokenKind::Number
                | tokenizer::TokenKind::Minus
                | tokenizer::TokenKind::Plus => {
                    tstart = parse_si_value(tok);
                    // Optional tmax after tstart — consume but don't store
                    if matches!(
                        tok.peek(),
                        tokenizer::TokenKind::Number
                            | tokenizer::TokenKind::Minus
                            | tokenizer::TokenKind::Plus
                    ) {
                        let _ = parse_si_value(tok);
                    }
                    // Check for trailing UIC keyword
                    if tok.peek() == tokenizer::TokenKind::Word {
                        let word_tok = tok.advance();
                        let w = std::str::from_utf8(word_tok.text)
                            .unwrap_or("")
                            .to_ascii_lowercase();
                        if w == "uic" {
                            uic = true;
                        }
                    }
                }
                tokenizer::TokenKind::Word => {
                    // Could be UIC keyword or a tstart value written as word
                    let w = {
                        let token = tok.advance();
                        std::str::from_utf8(token.text).unwrap_or("").to_ascii_lowercase()
                    };
                    if w == "uic" {
                        uic = true;
                    } else {
                        tstart = parse_word_as_value(&w);
                    }
                }
                _ => {}
            }
            // Drain rest of line
            tok.skip_line();
            analyses.push(InternalAnalysisKind::Transient { tstep, tstop, tstart, uic });
        }

        // ── .MODEL name type [(param=value ...)] ────────────────────────────
        Some(static_map::Directive::Model) => {
            // model name
            let model_name = if tok.peek() == tokenizer::TokenKind::Word {
                tok.consume_word()
            } else {
                tok.skip_line();
                return Ok(());
            };
            // model type
            let type_str = if tok.peek() == tokenizer::TokenKind::Word {
                tok.consume_word()
            } else {
                tok.skip_line();
                circuit.add_model(&model_name, ModelKind::Other(String::new()), ParamMap::new());
                return Ok(());
            };
            let kind = ModelKind::from_str(&type_str);
            // Optional parameter list, possibly wrapped in parentheses
            if tok.peek() == tokenizer::TokenKind::LeftParen {
                tok.advance(); // consume '('
            }
            let mut params = ParamMap::new();
            parse_kv_pairs(tok, &mut params);
            // consume closing paren if present
            if tok.peek() == tokenizer::TokenKind::RightParen {
                tok.advance();
            }
            tok.skip_line();
            circuit.add_model(&model_name, kind, params);
        }

        // ── .PARAM name=value [name2=value2 ...] ────────────────────────────
        //
        // Values can be:
        //   .PARAM Vdd=5.0            → plain numeric
        //   .PARAM Vhalf={Vdd/2}      → expression in braces (BraceExpr token)
        //
        // Plain numeric params are stored immediately in circuit.global_params.
        // Expression params are deferred to raw_params for post-parse evaluation.
        Some(static_map::Directive::Param) => {
            loop {
                match tok.peek() {
                    tokenizer::TokenKind::Word => {
                        let word_tok = tok.advance();
                        let key = std::str::from_utf8(word_tok.text)
                            .unwrap_or("")
                            .to_ascii_lowercase();
                        if tok.peek() == tokenizer::TokenKind::Equals {
                            tok.advance(); // consume '='
                            match tok.peek() {
                                tokenizer::TokenKind::BraceExpr => {
                                    // Expression wrapped in { } — defer for post-parse evaluation.
                                    let brace_tok = tok.advance();
                                    let raw = std::str::from_utf8(brace_tok.text)
                                        .unwrap_or("{}")
                                        .to_string();
                                    raw_params.push((key, raw));
                                }
                                tokenizer::TokenKind::SingleQuote => {
                                    // HSPICE-style 'expr' — defer for post-parse evaluation.
                                    let sq_tok = tok.advance();
                                    let raw = std::str::from_utf8(sq_tok.text).unwrap_or("''");
                                    // Strip surrounding single quotes before storing.
                                    let inner = raw.trim_matches('\'').to_string();
                                    raw_params.push((key, inner));
                                }
                                _ => {
                                    // Plain numeric value — evaluate immediately.
                                    let value = parse_si_value(tok);
                                    // Store both in circuit (for immediate use) and in
                                    // raw_params so the topo-sort pass has a complete list.
                                    circuit.set_global_param(&key, value);
                                    raw_params.push((key, format!("{value}")));
                                }
                            }
                        } else {
                            // Not a kv pair — stop
                            break;
                        }
                    }
                    tokenizer::TokenKind::Newline
                    | tokenizer::TokenKind::Eof
                    | tokenizer::TokenKind::Comment => break,
                    _ => break,
                }
            }
            tok.skip_line();
        }

        // ── .IC V(node)=voltage [...] ───────────────────────────────────────
        Some(static_map::Directive::Ic) => {
            // Each entry looks like: V(nodename)=value
            // Tokenizer: Word("V"), LeftParen, Word(nodename), RightParen, Equals, Number
            loop {
                match tok.peek() {
                    tokenizer::TokenKind::Word => {
                        // Expect "V" or "v"
                        let word_tok = tok.advance();
                        let kw = std::str::from_utf8(word_tok.text)
                            .unwrap_or("")
                            .to_ascii_lowercase();
                        if kw != "v" {
                            // Not a V(...) spec — skip rest
                            tok.skip_line();
                            break;
                        }
                        // Expect '('
                        if tok.peek() == tokenizer::TokenKind::LeftParen {
                            tok.advance();
                        } else {
                            tok.skip_line();
                            break;
                        }
                        // Node name
                        let node_name = match tok.peek() {
                            tokenizer::TokenKind::Word => tok.consume_word(),
                            tokenizer::TokenKind::Number => {
                                let t = tok.advance();
                                std::str::from_utf8(t.text).unwrap_or("0").to_string()
                            }
                            _ => {
                                tok.skip_line();
                                break;
                            }
                        };
                        // Expect ')'
                        if tok.peek() == tokenizer::TokenKind::RightParen {
                            tok.advance();
                        }
                        // Expect '='
                        if tok.peek() == tokenizer::TokenKind::Equals {
                            tok.advance();
                        } else {
                            tok.skip_line();
                            break;
                        }
                        let voltage = parse_si_value(tok);
                        let node_id = circuit.add_node(&node_name);
                        circuit.add_initial_condition(node_id, voltage);
                    }
                    tokenizer::TokenKind::Newline
                    | tokenizer::TokenKind::Eof
                    | tokenizer::TokenKind::Comment => break,
                    _ => {
                        tok.advance();
                        break;
                    }
                }
            }
            tok.skip_line();
        }

        // ── .NODESET V(node)=voltage [...] ─────────────────────────────────
        Some(static_map::Directive::Nodeset) => {
            loop {
                match tok.peek() {
                    tokenizer::TokenKind::Word => {
                        let word_tok = tok.advance();
                        let kw = std::str::from_utf8(word_tok.text)
                            .unwrap_or("")
                            .to_ascii_lowercase();
                        if kw != "v" {
                            tok.skip_line();
                            break;
                        }
                        if tok.peek() == tokenizer::TokenKind::LeftParen {
                            tok.advance();
                        } else {
                            tok.skip_line();
                            break;
                        }
                        let node_name = match tok.peek() {
                            tokenizer::TokenKind::Word => tok.consume_word(),
                            tokenizer::TokenKind::Number => {
                                let t = tok.advance();
                                std::str::from_utf8(t.text).unwrap_or("0").to_string()
                            }
                            _ => {
                                tok.skip_line();
                                break;
                            }
                        };
                        if tok.peek() == tokenizer::TokenKind::RightParen {
                            tok.advance();
                        }
                        if tok.peek() == tokenizer::TokenKind::Equals {
                            tok.advance();
                        } else {
                            tok.skip_line();
                            break;
                        }
                        let voltage = parse_si_value(tok);
                        let node_id = circuit.add_node(&node_name);
                        circuit.add_node_set(node_id, voltage);
                    }
                    tokenizer::TokenKind::Newline
                    | tokenizer::TokenKind::Eof
                    | tokenizer::TokenKind::Comment => break,
                    _ => {
                        tok.advance();
                        break;
                    }
                }
            }
            tok.skip_line();
        }

        // ── .SUBCKT name term1 term2 ... [param=default ...] ───────────────
        Some(static_map::Directive::Subckt) => {
            // Parse subcircuit name
            let subckt_name = if tok.peek() == tokenizer::TokenKind::Word {
                tok.consume_word()
            } else {
                tok.skip_line();
                return Ok(());
            };

            // Collect terminal names (bare words) and optional param=default pairs
            let mut terminals: Vec<String> = Vec::new();
            let mut def_params = ParamMap::new();

            loop {
                match tok.peek() {
                    tokenizer::TokenKind::Word => {
                        let word_tok = tok.advance();
                        let word = std::str::from_utf8(word_tok.text)
                            .unwrap_or("")
                            .to_string();
                        if tok.peek() == tokenizer::TokenKind::Equals {
                            // param=default pair
                            tok.advance();
                            let val = parse_si_value(tok);
                            def_params.set(&word.to_ascii_lowercase(), val);
                        } else {
                            // terminal name — preserve case
                            terminals.push(word);
                        }
                    }
                    tokenizer::TokenKind::Newline
                    | tokenizer::TokenKind::Eof
                    | tokenizer::TokenKind::Comment => break,
                    _ => { tok.advance(); }
                }
            }
            tok.skip_line();

            // Now accumulate body lines until .ENDS
            // We collect the raw text for each line.
            let mut body: Vec<u8> = Vec::new();
            loop {
                match tok.peek() {
                    tokenizer::TokenKind::Eof => break,
                    tokenizer::TokenKind::Dot => {
                        // Check if it's .ENDS
                        // We have to consume the dot and the directive word to test.
                        let _dot = tok.advance(); // consume '.'
                        let kw = tok.consume_word();
                        if kw == "ends" {
                            // Consume optional subckt name after .ENDS
                            if tok.peek() == tokenizer::TokenKind::Word {
                                tok.advance();
                            }
                            tok.skip_line();
                            break;
                        } else {
                            // Not .ENDS — encode back as a synthetic directive line in body.
                            // We can't un-consume tokens, so we reconstruct the line prefix
                            // and push it to body, then continue collecting until newline.
                            body.push(b'.');
                            body.extend_from_slice(kw.as_bytes());
                            body.push(b' ');
                            // Drain the rest of the line into body
                            loop {
                                match tok.peek() {
                                    tokenizer::TokenKind::Newline | tokenizer::TokenKind::Eof => break,
                                    tokenizer::TokenKind::Comment => break,
                                    _ => {
                                        let t = tok.advance();
                                        body.extend_from_slice(t.text);
                                        body.push(b' ');
                                    }
                                }
                            }
                            tok.skip_line();
                            body.push(b'\n');
                        }
                    }
                    tokenizer::TokenKind::Comment => {
                        tok.advance();
                    }
                    tokenizer::TokenKind::Newline => {
                        tok.advance();
                        body.push(b'\n');
                    }
                    _ => {
                        // Element or other token — collect the line into body
                        loop {
                            match tok.peek() {
                                tokenizer::TokenKind::Newline | tokenizer::TokenKind::Eof => break,
                                tokenizer::TokenKind::Comment => break,
                                _ => {
                                    let t = tok.advance();
                                    body.extend_from_slice(t.text);
                                    body.push(b' ');
                                }
                            }
                        }
                        tok.skip_line();
                        body.push(b'\n');
                    }
                }
            }

            let def = SubcktDef {
                name: subckt_name.clone(),
                terminals,
                params: def_params,
                body,
            };
            circuit.add_subckt_def(def);
        }

        // .ENDS without matching .SUBCKT — skip (should not appear at top level)
        Some(static_map::Directive::Ends) => {
            tok.skip_line();
        }

        // ── .OPTIONS opt1=val1 opt2=val2 ... ───────────────────────────────
        Some(static_map::Directive::Options) => {
            loop {
                match tok.peek() {
                    tokenizer::TokenKind::Word => {
                        let word_tok = tok.advance();
                        let key = std::str::from_utf8(word_tok.text)
                            .unwrap_or("")
                            .to_ascii_lowercase();
                        if tok.peek() == tokenizer::TokenKind::Equals {
                            tok.advance(); // consume '='
                            let val = parse_si_value(tok);
                            match key.as_str() {
                                "reltol"  => options.reltol  = Some(val),
                                "abstol"  => options.abstol  = Some(val),
                                "vntol"   => options.vntol   = Some(val),
                                "gmin"    => options.gmin    = Some(val),
                                "temp"    => {
                                    // Convert Celsius to Kelvin (SPICE uses Celsius)
                                    let kelvin = val + 273.15;
                                    circuit.add_temperature(kelvin);
                                }
                                _ => {
                                    // Unknown option — store in extras map
                                    options.extras.insert(key, val);
                                }
                            }
                        }
                        // else: bare word option without value (e.g. NOMOD) — ignore
                    }
                    tokenizer::TokenKind::Newline
                    | tokenizer::TokenKind::Eof
                    | tokenizer::TokenKind::Comment => break,
                    _ => { tok.advance(); }
                }
            }
            tok.skip_line();
        }

        // ── .INCLUDE "filename" ─────────────────────────────────────────────
        Some(static_map::Directive::Include) => {
            // Expect a quoted string token
            let path_str = if tok.peek() == tokenizer::TokenKind::QuotedString {
                let t = tok.advance();
                let raw = std::str::from_utf8(t.text).unwrap_or("\"\"");
                // Strip surrounding quotes
                raw.trim_matches('"').to_string()
            } else if tok.peek() == tokenizer::TokenKind::Word {
                tok.consume_word()
            } else {
                tok.skip_line();
                return Ok(());
            };
            tok.skip_line();

            let include_path = SpiceParser::resolve_include_path(&path_str);

            // Attempt to read and parse the included file.
            match std::fs::read(&include_path) {
                Ok(content) => {
                    // Parse included file into the same circuit (inlined).
                    // We spin up a new tokenizer for the included content and
                    // drive the same parse loop.
                    SpiceParser::with_include_dir(include_path.parent(), || {
                        let mut inc_tok = tokenizer::Tokenizer::new(&content);
                        // Included files typically have a title line — skip it.
                        // To stay safe we skip it unconditionally, matching SpiceParser behaviour.
                        inc_tok.skip_line();
                        while inc_tok.peek() != tokenizer::TokenKind::Eof {
                            match inc_tok.peek() {
                                tokenizer::TokenKind::Dot => {
                                    let inc_directive = inc_tok.consume_directive();
                                    parse_directive(&inc_directive, &mut inc_tok, circuit, analyses, options, raw_params, func_defs)?;
                                }
                                tokenizer::TokenKind::Word => {
                                    let mut _local_pending: Vec<(DeviceId, String, usize)> = Vec::new();
                                    let mut _local_pending_k: Vec<(String, String, f64)> = Vec::new();
                                    let mut _local_pending_exprs: Vec<(String, String, String)> = Vec::new();
                                    parse_element(&mut inc_tok, circuit, &mut _local_pending, &mut _local_pending_k, &mut _local_pending_exprs)?;
                                }
                                tokenizer::TokenKind::Newline | tokenizer::TokenKind::Comment => {
                                    inc_tok.advance();
                                }
                                _ => { inc_tok.advance(); }
                            }
                        }
                        Ok::<(), ParseError>(())
                    })?;
                }
                Err(e) => {
                    return Err(ParseError::Syntax {
                        line: 0,
                        msg: format!(".INCLUDE {:?}: {}", include_path, e),
                    });
                }
            }
        }

        // ── .GLOBAL node1 node2 ... ─────────────────────────────────────────
        Some(static_map::Directive::Global) => {
            loop {
                match tok.peek() {
                    tokenizer::TokenKind::Word => {
                        let name = tok.consume_word();
                        circuit.add_global(&name);
                    }
                    tokenizer::TokenKind::Newline
                    | tokenizer::TokenKind::Eof
                    | tokenizer::TokenKind::Comment => break,
                    _ => { tok.advance(); }
                }
            }
            tok.skip_line();
        }

        // ── .TEMP value [value ...] ─────────────────────────────────────────
        Some(static_map::Directive::Temp) => {
            // .TEMP takes Celsius values; convert to Kelvin.
            loop {
                match tok.peek() {
                    tokenizer::TokenKind::Number
                    | tokenizer::TokenKind::Minus
                    | tokenizer::TokenKind::Plus => {
                        let celsius = parse_si_value(tok);
                        circuit.add_temperature(celsius + 273.15);
                    }
                    tokenizer::TokenKind::Word => {
                        // Could be a numeric word like "27"
                        let w = tok.consume_word();
                        if let Ok(c) = w.parse::<f64>() {
                            circuit.add_temperature(c + 273.15);
                        } else {
                            break;
                        }
                    }
                    _ => break,
                }
            }
            tok.skip_line();
        }

        // ── .SAVE / .PRINT / .PLOT — output directives, skip ───────────────
        Some(static_map::Directive::Save)
        | Some(static_map::Directive::Print)
        | Some(static_map::Directive::Plot) => {
            tok.skip_line();
        }

        // ── .FUNC name(arg1, arg2, ...) {expr} ─────────────────────────────
        Some(static_map::Directive::Func) => {
            // Parse: .func name(args) {expr} or .func name(args) = expr
            let func_name = if tok.peek() == tokenizer::TokenKind::Word {
                tok.consume_word().to_ascii_lowercase()
            } else {
                tok.skip_line();
                return Ok(());
            };
            // Expect '('
            if tok.peek() != tokenizer::TokenKind::LeftParen {
                tok.skip_line();
                return Ok(());
            }
            tok.advance();
            // Collect argument names
            let mut arg_names: Vec<String> = Vec::new();
            loop {
                match tok.peek() {
                    tokenizer::TokenKind::Word => {
                        arg_names.push(tok.consume_word().to_ascii_lowercase());
                        if tok.peek() == tokenizer::TokenKind::RightParen {
                            tok.advance();
                            break;
                        }
                        // skip comma
                        if tok.peek() != tokenizer::TokenKind::Word
                            && tok.peek() != tokenizer::TokenKind::RightParen
                        {
                            tok.advance(); // consume comma or whitespace
                        }
                    }
                    tokenizer::TokenKind::RightParen => {
                        tok.advance();
                        break;
                    }
                    tokenizer::TokenKind::Newline | tokenizer::TokenKind::Eof => break,
                    _ => { tok.advance(); }
                }
            }
            // Skip optional '='
            if tok.peek() == tokenizer::TokenKind::Equals {
                tok.advance();
            }
            // Parse body: either {expr} or bare expression
            let body = match tok.peek() {
                tokenizer::TokenKind::BraceExpr => {
                    let t = tok.advance();
                    std::str::from_utf8(t.text).unwrap_or("{}").to_string()
                }
                _ => {
                    // Collect rest of line as body
                    let mut body_parts = Vec::new();
                    while tok.peek() != tokenizer::TokenKind::Newline
                        && tok.peek() != tokenizer::TokenKind::Eof
                        && tok.peek() != tokenizer::TokenKind::Comment
                    {
                        let t = tok.advance();
                        if let Ok(s) = std::str::from_utf8(t.text) {
                            body_parts.push(s.to_string());
                        }
                    }
                    body_parts.join("")
                }
            };
            tok.skip_line();
            func_defs.push((func_name, arg_names, body));
        }

        // ── .NOISE V(output) Vsource sweep_type npoints fstart fstop ──────────
        Some(static_map::Directive::Noise) => {
            // Parse "V(output_node)" or just "output_node"
            let output_node = if tok.peek() == tokenizer::TokenKind::Word {
                let w = tok.consume_word();
                let wl = w.to_ascii_lowercase();
                if wl == "v" && tok.peek() == tokenizer::TokenKind::LeftParen {
                    tok.advance(); // consume '('
                    let node = tok.consume_word();
                    if tok.peek() == tokenizer::TokenKind::RightParen {
                        tok.advance();
                    }
                    node.to_ascii_lowercase()
                } else {
                    wl
                }
            } else {
                tok.skip_line();
                return Ok(());
            };
            // Input source name
            let source = if tok.peek() == tokenizer::TokenKind::Word {
                tok.consume_word().to_ascii_lowercase()
            } else {
                tok.skip_line();
                return Ok(());
            };
            // Sweep type
            let sweep_type_str = if tok.peek() == tokenizer::TokenKind::Word {
                tok.consume_word().to_ascii_uppercase()
            } else {
                "DEC".to_string()
            };
            // npoints
            let npoints = match tok.peek() {
                tokenizer::TokenKind::Number => tok.consume_number() as usize,
                tokenizer::TokenKind::Word => {
                    let w = tok.consume_word();
                    w.parse::<usize>().unwrap_or(50)
                }
                _ => 50,
            };
            let fstart = parse_si_value(tok);
            let fstop = parse_si_value(tok);
            tok.skip_line();
            let sweep = match sweep_type_str.as_str() {
                "LIN" => AcSweepType::Lin(npoints),
                "OCT" => AcSweepType::Oct(npoints),
                _ => AcSweepType::Dec(npoints),
            };
            analyses.push(InternalAnalysisKind::Noise {
                output: output_node,
                source,
                sweep,
                fstart,
                fstop,
                npoints,
            });
        }

        Some(static_map::Directive::Control) => {
            // Skip .control/.endc blocks (interactive commands, not circuit description)
            tok.skip_line(); // skip rest of .control line
            loop {
                match tok.peek() {
                    tokenizer::TokenKind::Dot => {
                        let d = tok.consume_directive();
                        if d.eq_ignore_ascii_case("endc") {
                            tok.skip_line();
                            break;
                        }
                        tok.skip_line();
                    }
                    tokenizer::TokenKind::Eof => break,
                    _ => {
                        tok.skip_line();
                    }
                }
            }
        }

        // ── .SP LIN|DEC|OCT npoints fstart fstop ───────────────────────
        Some(static_map::Directive::Sp) => {
            let sweep_type_str = if tok.peek() == tokenizer::TokenKind::Word {
                tok.consume_word().to_ascii_uppercase()
            } else {
                tok.skip_line();
                analyses.push(InternalAnalysisKind::Sp {
                    num_ports: 0,
                    sweep: AcSweepType::Dec(10),
                    fstart: 1.0,
                    fstop: 1e9,
                });
                return Ok(());
            };
            let npoints = match tok.peek() {
                tokenizer::TokenKind::Number => tok.consume_number() as usize,
                tokenizer::TokenKind::Word => {
                    let w = tok.consume_word();
                    parse_word_as_value(&w) as usize
                }
                _ => 10,
            };
            let fstart = parse_si_value(tok);
            let fstop = parse_si_value(tok);
            tok.skip_line();
            let sweep = match sweep_type_str.as_str() {
                "LIN" => AcSweepType::Lin(npoints),
                "OCT" => AcSweepType::Oct(npoints),
                _ => AcSweepType::Dec(npoints),
            };
            // num_ports is set to 0 here; will be patched after all devices are
            // parsed and port-bearing voltage sources are identified.
            analyses.push(InternalAnalysisKind::Sp {
                num_ports: 0,
                sweep,
                fstart,
                fstop,
            });
        }

        // ── .HB fund=<freq> nharm=<N> ───────────────────────────────────
        Some(static_map::Directive::Hb) => {
            let mut fundamental = 1e6;
            let mut harmonics = 5_usize;
            // Parse keyword=value pairs
            loop {
                match tok.peek() {
                    tokenizer::TokenKind::Newline | tokenizer::TokenKind::Eof => break,
                    tokenizer::TokenKind::Word => {
                        let kw = tok.consume_word().to_ascii_lowercase();
                        if tok.peek() == tokenizer::TokenKind::Equals {
                            tok.advance();
                        }
                        match kw.as_str() {
                            "fund" => fundamental = parse_si_value(tok),
                            "nharm" | "harmonics" => harmonics = parse_si_value(tok) as usize,
                            _ => {}
                        }
                    }
                    tokenizer::TokenKind::Comment => { tok.skip_line(); break; }
                    _ => { tok.advance(); }
                }
            }
            analyses.push(InternalAnalysisKind::Hb { fundamental, harmonics });
        }

        // ── .PSS fund=<freq> [harms=<N>] ────────────────────────────────
        Some(static_map::Directive::Pss) => {
            let mut fundamental = 1e6;
            loop {
                match tok.peek() {
                    tokenizer::TokenKind::Newline | tokenizer::TokenKind::Eof => break,
                    tokenizer::TokenKind::Word => {
                        let kw = tok.consume_word().to_ascii_lowercase();
                        if tok.peek() == tokenizer::TokenKind::Equals {
                            tok.advance();
                        }
                        match kw.as_str() {
                            "fund" | "fundamental" => fundamental = parse_si_value(tok),
                            _ => {}
                        }
                    }
                    tokenizer::TokenKind::Comment => { tok.skip_line(); break; }
                    _ => { tok.advance(); }
                }
            }
            analyses.push(InternalAnalysisKind::Pss { fundamental });
        }

        // ── .LIB "filename" section ────────────────────────────────────────
        Some(static_map::Directive::Lib) => {
            // .lib "file" section — include only the named section from file
            let path_str = if tok.peek() == tokenizer::TokenKind::QuotedString {
                let t = tok.advance();
                let raw = std::str::from_utf8(t.text).unwrap_or("\"\"");
                raw.trim_matches('"').to_string()
            } else if tok.peek() == tokenizer::TokenKind::Word {
                tok.consume_word()
            } else {
                tok.skip_line();
                return Ok(());
            };
            // Section name follows the filename
            let section = if tok.peek() == tokenizer::TokenKind::Word {
                tok.consume_word().to_ascii_lowercase()
            } else {
                tok.skip_line();
                return Ok(());
            };
            tok.skip_line();

            let lib_path = SpiceParser::resolve_include_path(&path_str);
            match std::fs::read(&lib_path) {
                Ok(content) => {
                    // Extract the named section: .lib <section> ... .endl <section>
                    // Tracks nesting depth so that nested .lib/.endl pairs inside
                    // the target section are collected verbatim rather than
                    // prematurely terminating extraction.
                    let text = String::from_utf8_lossy(&content);
                    let mut in_section = false;
                    let mut depth: usize = 0;
                    let mut section_lines: Vec<String> = Vec::new();
                    for line in text.lines() {
                        let trimmed = line.trim().to_ascii_lowercase();
                        if !in_section {
                            // Match ".lib <section>" (start of target section)
                            if trimmed.starts_with(".lib") && !trimmed.contains('"') {
                                let parts: Vec<&str> = trimmed.split_whitespace().collect();
                                if parts.len() >= 2 && parts[1] == section {
                                    in_section = true;
                                    depth = 1;
                                }
                            }
                        } else if trimmed.starts_with(".lib") && !trimmed.contains('"') {
                            // Nested .lib definition — increase depth and keep the line
                            depth += 1;
                            section_lines.push(line.to_string());
                        } else if trimmed.starts_with(".endl") {
                            depth -= 1;
                            if depth == 0 {
                                // End of target section
                                break;
                            }
                            // Nested .endl — keep the line
                            section_lines.push(line.to_string());
                        } else {
                            section_lines.push(line.to_string());
                        }
                    }
                    if !section_lines.is_empty() {
                        // Parse extracted section content
                        let section_text = section_lines.join("\n");
                        let section_bytes = section_text.as_bytes();
                        SpiceParser::with_include_dir(lib_path.parent(), || {
                            let mut lib_tok = tokenizer::Tokenizer::new(section_bytes);
                            while lib_tok.peek() != tokenizer::TokenKind::Eof {
                                match lib_tok.peek() {
                                    tokenizer::TokenKind::Dot => {
                                        let lib_directive = lib_tok.consume_directive();
                                        parse_directive(&lib_directive, &mut lib_tok, circuit, analyses, options, raw_params, func_defs)?;
                                    }
                                    tokenizer::TokenKind::Word => {
                                        let mut _lp: Vec<(DeviceId, String, usize)> = Vec::new();
                                        let mut _lk: Vec<(String, String, f64)> = Vec::new();
                                        let mut _le: Vec<(String, String, String)> = Vec::new();
                                        parse_element(&mut lib_tok, circuit, &mut _lp, &mut _lk, &mut _le)?;
                                    }
                                    tokenizer::TokenKind::Newline | tokenizer::TokenKind::Comment => {
                                        lib_tok.advance();
                                    }
                                    _ => { lib_tok.advance(); }
                                }
                            }
                            Ok::<(), ParseError>(())
                        })?;
                    }
                }
                Err(_) => {
                    eprintln!("incspice-parser: .LIB {:?} not found, skipping", lib_path);
                }
            }
        }

        Some(static_map::Directive::Tf) => {
            eprintln!("warning: .TF not yet implemented, skipping");
            tok.skip_line();
        }
        Some(static_map::Directive::Pz) => {
            eprintln!("warning: .PZ not yet implemented, skipping");
            tok.skip_line();
        }
        Some(static_map::Directive::Sens) => {
            eprintln!("warning: .SENS not yet implemented, skipping");
            tok.skip_line();
        }
        _ => {
            // Skip unknown/unimplemented directives
            tok.skip_line();
        }
    }
    Ok(())
}

/// Parse a SPICE SI value from the next token.
///
/// Handles both `Number` tokens (e.g. `1k`, `4.7u`, `1e-9`) and
/// `Word` tokens that happen to look like values (rare, but tolerant).
/// Returns `0.0` on any parse failure so the caller can continue.
fn parse_si_value(tok: &mut tokenizer::Tokenizer<'_>) -> f64 {
    match tok.peek() {
        tokenizer::TokenKind::Number => tok.consume_number(),
        tokenizer::TokenKind::Minus => {
            tok.advance(); // consume '-'
            -parse_si_value(tok)
        }
        tokenizer::TokenKind::Plus => {
            tok.advance(); // consume '+'
            parse_si_value(tok)
        }
        tokenizer::TokenKind::Word => {
            // Some netlists write a value as a plain word (e.g. model name used
            // by mistake, or an expression we can't evaluate). Try parsing it
            // as a number with SI suffix; fall back to 0.0.
            let w = tok.consume_word();
            parse_word_as_value(&w)
        }
        _ => 0.0,
    }
}

/// Parse trailing keywords on V/I source lines after AC/waveform specs.
///
/// Recognises `portnum N`, `z0 Z`, `pwr V`, `freq F` and `key=value` pairs.
/// Stops at end of line, EOF, or comment.
fn parse_source_trailing(
    tok: &mut tokenizer::Tokenizer<'_>,
    params: &mut ParamMap,
) {
    loop {
        match tok.peek() {
            tokenizer::TokenKind::Newline | tokenizer::TokenKind::Eof => break,
            tokenizer::TokenKind::Comment => { tok.skip_line(); break; }
            tokenizer::TokenKind::Word => {
                let kw = tok.consume_word().to_ascii_lowercase();
                // Handle keyword=value or keyword value forms
                if tok.peek() == tokenizer::TokenKind::Equals {
                    tok.advance(); // consume '='
                }
                match kw.as_str() {
                    "portnum" | "z0" | "pwr" | "freq" => {
                        let val = parse_si_value(tok);
                        params.set(&kw, val);
                    }
                    "pulse" | "sin" | "exp" | "pwl" | "sffm" | "am" => {
                        parse_waveform_into_params(&kw, tok, params);
                    }
                    _ => {
                        // Try to parse as key=value if '=' follows, else skip
                        if matches!(tok.peek(), tokenizer::TokenKind::Number
                            | tokenizer::TokenKind::Minus | tokenizer::TokenKind::Plus) {
                            let val = parse_si_value(tok);
                            params.set(&kw, val);
                        }
                    }
                }
            }
            _ => { tok.advance(); }
        }
    }
}

/// Parse trailing key=value pairs until end of line.
/// Handles `ac=`, `m=`, `scale=`, etc. on R/C/L device lines.
fn parse_trailing_kv(
    tok: &mut tokenizer::Tokenizer<'_>,
    params: &mut ParamMap,
    circuit: &Circuit,
) {
    loop {
        match tok.peek() {
            tokenizer::TokenKind::Newline | tokenizer::TokenKind::Eof => {
                if tok.peek() == tokenizer::TokenKind::Newline {
                    tok.advance();
                }
                break;
            }
            tokenizer::TokenKind::Word => {
                let key = tok.consume_word();
                if tok.peek() == tokenizer::TokenKind::Equals {
                    tok.advance(); // consume '='
                    let val = parse_expr_or_si_value(tok, circuit);
                    params.set(&key, val);
                } else {
                    // Standalone word (possibly model name) — skip
                }
            }
            tokenizer::TokenKind::Comment => {
                tok.skip_line();
                break;
            }
            _ => {
                tok.advance(); // skip unknown token
            }
        }
    }
}

/// Parse the degree from a POLY keyword.
///
/// The degree may be embedded in the word itself (e.g. "poly(2)") or may
/// follow as separate tokens: `POLY`, `(`, `2`, `)`.
/// Returns the polynomial degree (defaults to 1 if unparseable).
fn parse_poly_degree(word: &str, tok: &mut tokenizer::Tokenizer<'_>) -> u32 {
    // Try to extract from "poly(N)" directly
    if let Some(start) = word.find('(') {
        if let Some(end) = word.find(')') {
            if let Ok(n) = word[start + 1..end].trim().parse::<u32>() {
                return n;
            }
        }
        // Partial: "poly(" without closing paren — degree is next token
        let deg = parse_si_value(tok) as u32;
        if tok.peek() == tokenizer::TokenKind::RightParen {
            tok.advance();
        }
        return if deg == 0 { 1 } else { deg };
    }
    // Word is just "poly" — expect (N) as separate tokens
    if tok.peek() == tokenizer::TokenKind::LeftParen {
        tok.advance();
        let deg = parse_si_value(tok) as u32;
        if tok.peek() == tokenizer::TokenKind::RightParen {
            tok.advance();
        }
        if deg == 0 { 1 } else { deg }
    } else {
        1 // default degree
    }
}

/// Try to parse a word-token as an SI-suffixed number.
///
/// Handles cases like "1k" that the tokenizer may occasionally emit as a
/// Word instead of Number (e.g. when the number starts with a letter-prefixed
/// expression).  Returns `0.0` if the word is not numeric.
fn parse_word_as_value(w: &str) -> f64 {
    if w.is_empty() {
        return 0.0;
    }
    // Find where the numeric part ends and the suffix begins.
    let bytes = w.as_bytes();
    let mut i = 0;
    if i < bytes.len() && (bytes[i] == b'+' || bytes[i] == b'-') {
        i += 1;
    }
    let num_start = i;
    while i < bytes.len() && (bytes[i].is_ascii_digit() || bytes[i] == b'.') {
        i += 1;
    }
    if i < bytes.len() && (bytes[i] == b'e' || bytes[i] == b'E') {
        i += 1;
        if i < bytes.len() && (bytes[i] == b'+' || bytes[i] == b'-') {
            i += 1;
        }
        while i < bytes.len() && bytes[i].is_ascii_digit() {
            i += 1;
        }
    }
    if i == num_start {
        return 0.0; // no numeric prefix at all
    }
    let num_part = &w[..i];
    let suffix = &w[i..];
    let base: f64 = num_part.parse().unwrap_or(0.0);
    if let Some(mult) = static_map::si_suffix(suffix.as_bytes()) {
        base * mult
    } else {
        base
    }
}

/// Parse a device value that may be a plain SI number OR a `{expr}` / `'expr'`
/// expression referencing global circuit parameters.
///
/// Falls back to `parse_si_value` for plain numeric tokens.
fn parse_expr_or_si_value(tok: &mut tokenizer::Tokenizer<'_>, circuit: &Circuit) -> f64 {
    match tok.peek() {
        tokenizer::TokenKind::BraceExpr | tokenizer::TokenKind::SingleQuote => {
            let t = tok.advance();
            let raw = std::str::from_utf8(t.text).unwrap_or("0");
            // Strip surrounding delimiters: {} or ''
            let inner = raw
                .trim()
                .trim_start_matches('{')
                .trim_end_matches('}')
                .trim_matches('\'');
            let mut eval = ExprEval::new();
            for (k, v) in &circuit.global_params {
                eval.set_var(k, *v);
            }
            eval.eval(inner).unwrap_or(0.0)
        }
        _ => parse_si_value(tok),
    }
}

/// Like `parse_expr_or_si_value` but also returns the raw expression string
/// (if the token was an expression). Returns `(value, Some(expr))` for
/// expressions or `(value, None)` for plain numeric values.
fn parse_expr_or_si_value_deferred(
    tok: &mut tokenizer::Tokenizer<'_>,
    circuit: &Circuit,
) -> (f64, Option<String>) {
    match tok.peek() {
        tokenizer::TokenKind::BraceExpr | tokenizer::TokenKind::SingleQuote => {
            let t = tok.advance();
            let raw = std::str::from_utf8(t.text).unwrap_or("0");
            let inner = raw
                .trim()
                .trim_start_matches('{')
                .trim_end_matches('}')
                .trim_matches('\'')
                .to_string();
            let mut eval = ExprEval::new();
            for (k, v) in &circuit.global_params {
                eval.set_var(k, *v);
            }
            let val = eval.eval(&inner).unwrap_or(0.0);
            (val, Some(inner))
        }
        _ => (parse_si_value(tok), None),
    }
}

/// Read the next token as a node name string and return its NodeId,
/// creating the node in the circuit if it doesn't already exist.
///
/// Handles both Word tokens (named nodes) and Number tokens (numeric node
/// names like "0", "1", "2" which are common in SPICE).
fn parse_node(tok: &mut tokenizer::Tokenizer<'_>, circuit: &mut Circuit) -> NodeId {
    match tok.peek() {
        tokenizer::TokenKind::Word => {
            let name = tok.consume_word();
            circuit.add_node(&name)
        }
        tokenizer::TokenKind::Number => {
            // Numeric node names: advance, convert token text back to string.
            let token = tok.advance();
            let name = std::str::from_utf8(token.text).unwrap_or("0");
            circuit.add_node(name)
        }
        _ => NodeId::GROUND,
    }
}

/// Parse keyword=value pairs until end of line.
///
/// Handles `KEY=VALUE` sequences where KEY is a Word token, `=` is an Equals
/// token, and VALUE is parseable by `parse_si_value`.  Any token that is not
/// a Word (or a Number token used as a key, which is unusual but tolerated)
/// stops the loop; it is NOT consumed so the caller can inspect it.
fn parse_kv_pairs(tok: &mut tokenizer::Tokenizer<'_>, params: &mut ParamMap) {
    loop {
        match tok.peek() {
            tokenizer::TokenKind::Word => {
                // Peek: consume word tentatively
                let word_tok = tok.advance();
                let key = std::str::from_utf8(word_tok.text)
                    .unwrap_or("")
                    .to_ascii_lowercase();
                if tok.peek() == tokenizer::TokenKind::Equals {
                    tok.advance(); // consume '='
                    let value = parse_si_value(tok);
                    params.set(&key, value);
                } else {
                    // Word not followed by '=' — this is the end of kv section
                    // (e.g. a trailing model name already consumed elsewhere).
                    // We've already advanced past it; just stop.
                    break;
                }
            }
            tokenizer::TokenKind::Newline
            | tokenizer::TokenKind::Eof
            | tokenizer::TokenKind::Comment => break,
            _ => break,
        }
    }
}

/// Parse positional numeric arguments from a waveform `(v1 v2 ...)` list.
///
/// Expects the `(` to be the next token (or already consumed — caller must
/// pass the remaining tokens starting with the args themselves).  Reads
/// values separated by whitespace and/or commas until `)` or end-of-line.
/// Returns values in order; trailing optional params default to `f64::NAN`
/// to allow callers to distinguish "not specified" from zero.
fn parse_waveform_args(tok: &mut tokenizer::Tokenizer<'_>) -> Vec<f64> {
    // Consume leading `(` if present.
    if tok.peek() == tokenizer::TokenKind::LeftParen {
        tok.advance();
    }
    let mut args: Vec<f64> = Vec::new();
    loop {
        match tok.peek() {
            tokenizer::TokenKind::RightParen => {
                tok.advance(); // consume `)`
                break;
            }
            tokenizer::TokenKind::Newline | tokenizer::TokenKind::Eof => break,
            tokenizer::TokenKind::Comma => {
                tok.advance(); // skip separator comma
            }
            _ => {
                let v = parse_si_value(tok);
                args.push(v);
            }
        }
    }
    args
}

/// Parse a waveform specification into `params`.
///
/// `kw` is the waveform keyword already consumed by the caller (lowercase),
/// e.g. `"pulse"`, `"sin"`, `"exp"`, `"pwl"`, `"sffm"`, `"am"`.
/// The parenthesised argument list starting with `(` is next in the token
/// stream (or the args themselves if `(` was consumed elsewhere).
///
/// On return, `params` contains `waveform_kind` and the appropriate
/// `pulse_*` / `sin_*` / `exp_*` / `pwl_*` / `sffm_*` / `am_*` keys.
fn parse_waveform_into_params(
    kw: &str,
    tok: &mut tokenizer::Tokenizer<'_>,
    params: &mut ParamMap,
) {
    let args = parse_waveform_args(tok);

    /// Return arg at `idx`, or `default` if not provided.
    fn a(args: &[f64], idx: usize, default: f64) -> f64 {
        *args.get(idx).unwrap_or(&default)
    }

    match kw {
        "pulse" => {
            // PULSE(v1 v2 [td [tr [tf [pw [per]]]]])
            params.set("waveform_kind", 1.0);
            params.set("pulse_v1", a(&args, 0, 0.0));
            params.set("pulse_v2", a(&args, 1, 0.0));
            params.set("pulse_td", a(&args, 2, 0.0));
            // tr and tf default to tstep — we use a very small value as
            // stand-in; the transient engine's timestep governs the edge.
            params.set("pulse_tr", a(&args, 3, 1e-12));
            params.set("pulse_tf", a(&args, 4, 1e-12));
            params.set("pulse_pw", a(&args, 5, f64::INFINITY));
            params.set("pulse_per", a(&args, 6, f64::INFINITY));
        }
        "sin" => {
            // SIN(vo va [freq [td [theta]]])
            params.set("waveform_kind", 2.0);
            params.set("sin_vo", a(&args, 0, 0.0));
            params.set("sin_va", a(&args, 1, 0.0));
            params.set("sin_freq", a(&args, 2, 1.0));
            params.set("sin_td", a(&args, 3, 0.0));
            params.set("sin_theta", a(&args, 4, 0.0));
        }
        "exp" => {
            // EXP(v1 v2 [td1 [tau1 [td2 [tau2]]]])
            params.set("waveform_kind", 4.0);
            params.set("exp_v1", a(&args, 0, 0.0));
            params.set("exp_v2", a(&args, 1, 0.0));
            params.set("exp_td1", a(&args, 2, 0.0));
            params.set("exp_tau1", a(&args, 3, 1e-12));
            params.set("exp_td2", a(&args, 4, 1e-12));
            params.set("exp_tau2", a(&args, 5, 1e-12));
        }
        "pwl" => {
            // PWL(t0 v0 t1 v1 ...) — arbitrary number of (time, value) pairs
            params.set("waveform_kind", 3.0);
            let n_pairs = args.len() / 2;
            params.set("pwl_count", n_pairs as f64);
            for i in 0..n_pairs {
                params.set(&format!("pwl_t{i}"), args[2 * i]);
                params.set(&format!("pwl_v{i}"), args[2 * i + 1]);
            }
        }
        "sffm" => {
            // SFFM(vo va fc mdi fs)
            params.set("waveform_kind", 5.0);
            params.set("sffm_vo", a(&args, 0, 0.0));
            params.set("sffm_va", a(&args, 1, 0.0));
            params.set("sffm_fc", a(&args, 2, 1.0));
            params.set("sffm_mdi", a(&args, 3, 0.0));
            params.set("sffm_fs", a(&args, 4, 1.0));
        }
        "am" => {
            // AM(va vo fc freq td)
            params.set("waveform_kind", 7.0);
            params.set("am_va", a(&args, 0, 0.0));
            params.set("am_vo", a(&args, 1, 0.0));
            params.set("am_fc", a(&args, 2, 1.0));
            params.set("am_freq", a(&args, 3, 1.0));
            params.set("am_td", a(&args, 4, 0.0));
        }
        _ => {
            // Unknown waveform type — skip remaining line tokens.
            tok.skip_line();
        }
    }
}

/// Map a `ModelKind` to the appropriate `DeviceKind`, choosing the LEVEL-based
/// variant for MOSFETs.
fn device_kind_from_model(kind: &incspice_core::ModelKind, params: &ParamMap) -> Option<DeviceKind> {
    use incspice_core::ModelKind;
    match kind {
        ModelKind::Nmos => {
            let level = params.get_or("level", 1.0) as u32;
            Some(match level {
                2 => DeviceKind::MosfetN2,
                3 => DeviceKind::MosfetN3,
                6 => DeviceKind::MosfetN6,
                8 | 49 => DeviceKind::Bsim3N,
                14 | 54 => DeviceKind::Bsim4N,
                _ => DeviceKind::MosfetN,
            })
        }
        ModelKind::Pmos => {
            let level = params.get_or("level", 1.0) as u32;
            Some(match level {
                2 => DeviceKind::MosfetP2,
                3 => DeviceKind::MosfetP3,
                6 => DeviceKind::MosfetP6,
                8 | 49 => DeviceKind::Bsim3P,
                14 | 54 => DeviceKind::Bsim4P,
                _ => DeviceKind::MosfetP,
            })
        }
        ModelKind::Npn => Some(DeviceKind::BjtNpn),
        ModelKind::Pnp => Some(DeviceKind::BjtPnp),
        ModelKind::Diode => Some(DeviceKind::Diode),
        _ => None,
    }
}

/// After the full netlist is parsed, merge `.MODEL` parameters into each
/// device that references a model by name.
///
/// Merge strategy: model params form the base; device-level params (W, L,
/// AREA, etc.) override.  Also updates the `DeviceKind` to match the model
/// type (e.g. PMOS → `MosfetP`, LEVEL=14 NMOS → `Bsim4N`).
///
/// For PMOS models the `pmos=1.0` sentinel is injected into the device params
/// Expand BJT extrinsic series resistances (RB, RC, RE) at the netlist level.
///
/// For each BJT (NPN or PNP) whose merged model parameters include nonzero
/// RB, RC, or RE values, this function:
///
/// 1. Creates internal nodes `_<name>_bx`, `_<name>_cx`, `_<name>_ex`.
/// 2. Rewires the BJT's terminals to the internal nodes.
/// 3. Adds explicit `Resistor` devices connecting each external terminal to
///    the corresponding internal node (collector→RC→internal_c, etc.).
/// 4. Clears `rb`, `rc`, `re` from the BJT params so `eval_with_extrinsic`
///    does not double-stamp the resistance.
///
/// This is equivalent to SPICE's internal BJT node expansion and allows the
/// intrinsic Gummel-Poon core to evaluate at the true internal node voltages
/// while the series resistances are handled as normal resistor elements.
///
/// Must be called **after** `merge_model_params` so that model params are
/// visible in `device.params`, and **before** `circuit.build_topology()`.
fn expand_bjt_extrinsic(circuit: &mut Circuit) {
    // Collect BJT device IDs and their extrinsic resistance values up front
    // to avoid borrow conflicts when mutating the circuit.
    let bjt_info: Vec<(usize, f64, f64, f64, String)> = circuit
        .devices()
        .iter()
        .enumerate()
        .filter(|(_, dev)| {
            dev.kind == DeviceKind::BjtNpn || dev.kind == DeviceKind::BjtPnp
        })
        .map(|(idx, dev)| {
            let rb = dev.params.get_or("rb", 0.0);
            let rc = dev.params.get_or("rc", 0.0);
            let re = dev.params.get_or("re", 0.0);
            (idx, rb, rc, re, dev.name.clone())
        })
        .filter(|(_, rb, rc, re, _)| *rb > 0.0 || *rc > 0.0 || *re > 0.0)
        .collect();

    let mut new_devices: Vec<DeviceInstance> = Vec::new();

    for (idx, rb, rc, re, dev_name) in bjt_info {
        let dev = &circuit.devices()[idx];

        // Get the external node for each BJT pin (pin 0=C, 1=B, 2=E).
        let ext_c = dev.node(0);
        let ext_b = dev.node(1);
        let ext_e = dev.node(2);

        // Create internal nodes.
        let int_c = circuit.add_node(&format!("_{}cx", dev_name));
        let int_b = circuit.add_node(&format!("_{}bx", dev_name));
        let int_e = circuit.add_node(&format!("_{}ex", dev_name));

        // Rewire BJT terminals to internal nodes.
        {
            let dev = &mut circuit.devices_mut()[idx];
            for term in dev.terminals.iter_mut() {
                match term.pin {
                    0 => term.node = int_c,
                    1 => term.node = int_b,
                    2 => term.node = int_e,
                    _ => {} // substrate and higher pins unchanged
                }
            }
            // Clear rb/rc/re so eval_with_extrinsic skips them.
            dev.params.remove("rb");
            dev.params.remove("rc");
            dev.params.remove("re");
        }

        // Add resistor devices connecting external ↔ internal nodes.
        // Use DeviceId::new(0) as placeholder — add_device() reassigns IDs.
        let dummy_id = DeviceId::new(0);

        if rc > 0.0 {
            if let (Some(n_ext), n_int) = (ext_c, int_c) {
                let mut r = DeviceInstance::new(
                    dummy_id,
                    format!("_RC_{}", dev_name),
                    DeviceKind::Resistor,
                    &[(0, n_ext), (1, n_int)],
                );
                r.params.set("resistance", rc);
                new_devices.push(r);
            }
        }

        if rb > 0.0 {
            if let (Some(n_ext), n_int) = (ext_b, int_b) {
                let mut r = DeviceInstance::new(
                    dummy_id,
                    format!("_RB_{}", dev_name),
                    DeviceKind::Resistor,
                    &[(0, n_ext), (1, n_int)],
                );
                r.params.set("resistance", rb);
                new_devices.push(r);
            }
        }

        if re > 0.0 {
            if let (Some(n_ext), n_int) = (ext_e, int_e) {
                let mut r = DeviceInstance::new(
                    dummy_id,
                    format!("_RE_{}", dev_name),
                    DeviceKind::Resistor,
                    &[(0, n_ext), (1, n_int)],
                );
                r.params.set("resistance", re);
                new_devices.push(r);
            }
        }
    }

    for dev in new_devices {
        circuit.add_device(dev);
    }
}

/// so that `MosfetLevel1/2/3/6::eval` can detect the polarity at evaluation
/// time (those models share the same `DeviceDispatch` variant as NMOS and
/// rely on this flag rather than on the `DeviceKind` discriminant).
fn merge_model_params(circuit: &mut Circuit, pending: &[(DeviceId, String, usize)]) -> Result<(), ParseError> {
    for (device_id, model_name, line) in pending {
        // Clone what we need from the model registry to avoid borrow conflict.
        let (model_kind, model_params) = match circuit.models.get(model_name) {
            Some((k, p)) => (k.clone(), p.clone()),
            None => {
                // No explicit .MODEL entry. Try to infer the DeviceKind from
                // the model name itself (e.g. "pmos" → MosfetP, "nmos" → MosfetN).
                // This handles subcircuit bodies that use built-in type keywords
                // as model names without an explicit .MODEL directive.
                let inferred = incspice_core::ModelKind::from_str(model_name);
                match &inferred {
                    incspice_core::ModelKind::Other(_) => {
                        // Undefined model — warn with device name, model name,
                        // and line number so the user can diagnose the issue.
                        let dev_name = &circuit.devices()[device_id.index()].name;
                        eprintln!(
                            "warning: line {}: device '{}' references undefined model '{}'",
                            line, dev_name, model_name
                        );
                    }
                    k => {
                        let dev_params = circuit.devices()[device_id.index()].params.clone();
                        if let Some(new_kind) = device_kind_from_model(k, &dev_params) {
                            let is_pmos = *k == incspice_core::ModelKind::Pmos;
                            let dev = &mut circuit.devices_mut()[device_id.index()];
                            dev.kind = new_kind;
                            if is_pmos {
                                dev.params.set("pmos", 1.0);
                            }
                        }
                    }
                }
                continue;
            }
        };

        // Merge: model params as base, device params override.
        let device = &mut circuit.devices_mut()[device_id.index()];
        let mut merged = model_params;
        for (k, v) in device.params.iter() {
            merged.set(k, v);
        }
        // Inject the PMOS polarity sentinel so that MosfetLevel1/2/3/6 eval
        // code can detect polarity from params alone (it checks pmos != 0.0).
        if model_kind == incspice_core::ModelKind::Pmos {
            merged.set("pmos", 1.0);
        }
        device.params = merged;

        // Update DeviceKind from model type.
        if let Some(new_kind) = device_kind_from_model(&model_kind, &device.params) {
            device.kind = new_kind;
        }
    }
    Ok(())
}

fn parse_element(
    tok: &mut tokenizer::Tokenizer<'_>,
    circuit: &mut Circuit,
    pending_models: &mut Vec<(DeviceId, String, usize)>,
    pending_k_elements: &mut Vec<(String, String, f64)>,
    pending_device_exprs: &mut Vec<(String, String, String)>,
) -> Result<(), ParseError> {
    let element_line = tok.current_line();
    let name = tok.consume_word();
    if name.is_empty() {
        tok.advance();
        return Ok(());
    }

    // First-letter dispatch (SPICE convention)
    let first = name.as_bytes()[0].to_ascii_lowercase();
    let kind = static_map::ELEMENT_PREFIX
        .get(&first)
        .copied()
        .unwrap_or(DeviceKind::Resistor);

    // ── Parse terminals and parameters based on element type ─────────────
    // On any parse error we fall through to skip_line and add the device with
    // whatever we managed to collect, rather than aborting the whole netlist.
    let mut terminals: Vec<(u8, NodeId)> = Vec::new();
    let mut params = ParamMap::new();
    // Model name for M/Q/D devices (stored as lowercase for later lookup).
    let mut device_model_name: Option<String> = None;
    // For X-devices: subckt name and ordered port NodeIds for SubcktCall registration.
    let mut x_subckt_name: Option<String> = None;
    let mut x_terminal_nodes: Vec<NodeId> = Vec::new();

    match first {
        // ── Two-terminal passives: R, C, L ────────────────────────────────
        b'r' => {
            // Rname node+ node- value [key=value ...] | Rname node+ node- modelname [L= W= ...]
            let nplus = parse_node(tok, circuit);
            let nminus = parse_node(tok, circuit);
            terminals.push((0, nplus));
            terminals.push((1, nminus));
            let (value, expr) = parse_expr_or_si_value_deferred(tok, circuit);
            params.set("resistance", value);
            if let Some(e) = expr {
                pending_device_exprs.push((name.to_lowercase(), "resistance".into(), e));
            }
            parse_trailing_kv(tok, &mut params, circuit);
        }
        b'c' => {
            // Cname node+ node- value [key=value ...]
            let nplus = parse_node(tok, circuit);
            let nminus = parse_node(tok, circuit);
            terminals.push((0, nplus));
            terminals.push((1, nminus));
            let (value, expr) = parse_expr_or_si_value_deferred(tok, circuit);
            params.set("capacitance", value);
            if let Some(e) = expr {
                pending_device_exprs.push((name.to_lowercase(), "capacitance".into(), e));
            }
            parse_trailing_kv(tok, &mut params, circuit);
        }
        b'l' => {
            // Lname node+ node- value [key=value ...]
            let nplus = parse_node(tok, circuit);
            let nminus = parse_node(tok, circuit);
            terminals.push((0, nplus));
            terminals.push((1, nminus));
            let (value, expr) = parse_expr_or_si_value_deferred(tok, circuit);
            params.set("inductance", value);
            if let Some(e) = expr {
                pending_device_exprs.push((name.to_lowercase(), "inductance".into(), e));
            }
            parse_trailing_kv(tok, &mut params, circuit);
        }

        // ── Independent sources: V, I ─────────────────────────────────────
        b'v' | b'i' => {
            // Vname node+ node- [DC] dc_value [AC ac_mag [ac_phase]]
            // Vname node+ node- PULSE(...) | SIN(...) | ...
            let nplus = parse_node(tok, circuit);
            let nminus = parse_node(tok, circuit);
            terminals.push((0, nplus));
            terminals.push((1, nminus));

            // Peek at next token: could be "dc", a number, or a waveform keyword.
            let dc_val = match tok.peek() {
                tokenizer::TokenKind::Newline | tokenizer::TokenKind::Eof => 0.0,
                tokenizer::TokenKind::Word => {
                    // Could be "dc", "ac", "pulse", "sin", "exp", "pwl", etc.
                    let kw = {
                        let token = tok.advance();
                        std::str::from_utf8(token.text)
                            .unwrap_or("")
                            .to_ascii_lowercase()
                    };
                    match kw.as_str() {
                        "dc" => {
                            // Explicit DC keyword followed by value (may be {expr})
                            let (v, expr) = parse_expr_or_si_value_deferred(tok, circuit);
                            if let Some(e) = expr {
                                pending_device_exprs.push((name.to_lowercase(), "dc".into(), e));
                            }
                            v
                        }
                        "ac" => {
                            // No DC value; AC spec follows
                            let ac_mag = parse_si_value(tok);
                            params.set("ac_mag", ac_mag);
                            if matches!(tok.peek(), tokenizer::TokenKind::Number
                                | tokenizer::TokenKind::Minus | tokenizer::TokenKind::Plus) {
                                let ac_phase = parse_si_value(tok);
                                params.set("ac_phase", ac_phase);
                            }
                            // Parse remaining trailing keywords (portnum, z0, etc.)
                            parse_source_trailing(tok, &mut params);
                            0.0 // no DC component
                        }
                        "pulse" | "sin" | "exp" | "pwl" | "sffm" | "am" => {
                            // Waveform source — parse args into params.
                            parse_waveform_into_params(&kw.clone(), tok, &mut params);
                            0.0
                        }
                        "portnum" | "z0" | "pwr" | "freq" => {
                            // Port or frequency parameters without DC/AC prefix.
                            let val = parse_si_value(tok);
                            params.set(&kw, val);
                            parse_source_trailing(tok, &mut params);
                            0.0
                        }
                        _ => {
                            // Unknown keyword — treat as 0.0 and skip line.
                            tok.skip_line();
                            0.0
                        }
                    }
                }
                tokenizer::TokenKind::Number
                | tokenizer::TokenKind::Minus
                | tokenizer::TokenKind::Plus => {
                    // Bare numeric DC value.
                    parse_si_value(tok)
                }
                tokenizer::TokenKind::BraceExpr | tokenizer::TokenKind::SingleQuote => {
                    // Param-expression DC value, e.g. V1 in 0 DC {vdd_val}
                    let (v, expr) = parse_expr_or_si_value_deferred(tok, circuit);
                    if let Some(e) = expr {
                        pending_device_exprs.push((name.to_lowercase(), "dc".into(), e));
                    }
                    v
                }
                _ => {
                    tok.skip_line();
                    0.0
                }
            };
            params.set("dc", dc_val);

            // Optional AC/waveform spec after DC value.
            // Handles: "DC 5 AC 1", "DC 5 SIN(...)", "0 SIN(...)", etc.
            if tok.peek() == tokenizer::TokenKind::Word {
                let token = tok.advance();
                let kw = std::str::from_utf8(token.text)
                    .unwrap_or("")
                    .to_ascii_lowercase();
                match kw.as_str() {
                    "ac" => {
                        let ac_mag = parse_si_value(tok);
                        params.set("ac_mag", ac_mag);
                        // AC phase: only consume if the next token is a number
                        // (not a keyword like "portnum").
                        if matches!(tok.peek(), tokenizer::TokenKind::Number
                            | tokenizer::TokenKind::Minus | tokenizer::TokenKind::Plus) {
                            let ac_phase = parse_si_value(tok);
                            params.set("ac_phase", ac_phase);
                        }
                        // After AC spec there may still be a waveform or port params.
                        parse_source_trailing(tok, &mut params);
                    }
                    "pulse" | "sin" | "exp" | "pwl" | "sffm" | "am" => {
                        // Waveform spec after a bare DC value.
                        parse_waveform_into_params(&kw, tok, &mut params);
                        parse_source_trailing(tok, &mut params);
                    }
                    "portnum" => {
                        // portnum N z0 Z (bare, no '=')
                        let pn = parse_si_value(tok);
                        params.set("portnum", pn);
                        parse_source_trailing(tok, &mut params);
                    }
                    "z0" => {
                        let z = parse_si_value(tok);
                        params.set("z0", z);
                        parse_source_trailing(tok, &mut params);
                    }
                    _ => {
                        // Unknown keyword — skip the rest of the line.
                        tok.skip_line();
                    }
                }
            }
            tok.skip_line();
        }

        // ── Diode: D ──────────────────────────────────────────────────────
        b'd' => {
            // Dname anode cathode model_name [AREA=value]
            let anode = parse_node(tok, circuit);
            let cathode = parse_node(tok, circuit);
            terminals.push((0, anode));
            terminals.push((1, cathode));
            // model name — store for later .MODEL lookup
            if tok.peek() == tokenizer::TokenKind::Word {
                let mname_tok = tok.advance();
                let mname = std::str::from_utf8(mname_tok.text)
                    .unwrap_or("")
                    .to_ascii_lowercase();
                if !mname.is_empty() {
                    device_model_name = Some(mname);
                }
            }
            // Optional AREA=value or bare area value
            if tok.peek() == tokenizer::TokenKind::Word {
                let token = tok.advance();
                let kw = std::str::from_utf8(token.text)
                    .unwrap_or("")
                    .to_ascii_lowercase();
                if kw == "area" {
                    // AREA=value
                    if tok.peek() == tokenizer::TokenKind::Equals {
                        tok.advance();
                    }
                    let area = parse_si_value(tok);
                    params.set("area", area);
                }
            } else if matches!(
                tok.peek(),
                tokenizer::TokenKind::Number | tokenizer::TokenKind::Equals
            ) {
                // bare numeric area
                if tok.peek() == tokenizer::TokenKind::Equals {
                    tok.advance();
                }
                let area = parse_si_value(tok);
                params.set("area", area);
            }
            tok.skip_line();
        }

        // ── MOSFET: M (4 terminals: D, G, S, B) ───────────────────────────
        b'm' => {
            // Mname drain gate source bulk model_name [W=value L=value ...]
            let drain = parse_node(tok, circuit);
            let gate = parse_node(tok, circuit);
            let source = parse_node(tok, circuit);
            let bulk = parse_node(tok, circuit);
            terminals.push((0, drain));
            terminals.push((1, gate));
            terminals.push((2, source));
            terminals.push((3, bulk));
            // model_name — store for later .MODEL lookup
            if tok.peek() == tokenizer::TokenKind::Word {
                let mname_tok = tok.advance();
                let mname = std::str::from_utf8(mname_tok.text)
                    .unwrap_or("")
                    .to_ascii_lowercase();
                if !mname.is_empty() {
                    device_model_name = Some(mname);
                }
            }
            // Parse keyword=value pairs (W, L, AD, AS, PD, PS, NRD, NRS, ...)
            parse_kv_pairs(tok, &mut params);
            tok.skip_line();
        }

        // ── BJT: Q (3 or 4 terminals: C, B, E [, substrate]) ─────────────
        b'q' => {
            // Qname collector base emitter [substrate] model_name [AREA=value ...]
            let collector = parse_node(tok, circuit);
            let base = parse_node(tok, circuit);
            let emitter = parse_node(tok, circuit);
            terminals.push((0, collector));
            terminals.push((1, base));
            terminals.push((2, emitter));

            // Lookahead: consume words until we find a model name or kv pair.
            // The model name is the last bare word before any kv pairs or EOL.
            // Strategy: peek ahead — if next token is a Word AND the token after
            // that is also a Word (not '='), treat the first as a 4th node.
            // Then consume the model name word.
            //
            // Simplified heuristic: if the next word is followed by another word
            // (not '='), assume it's the substrate node; otherwise it's the model.
            if tok.peek() == tokenizer::TokenKind::Word {
                // Consume tentative word
                let word_tok = tok.advance();
                let word_text = std::str::from_utf8(word_tok.text)
                    .unwrap_or("")
                    .to_ascii_lowercase();
                // Check if next token is also a plain word (not kv pair)
                if tok.peek() == tokenizer::TokenKind::Word {
                    // This word is the substrate node; next word is model name
                    let substrate = circuit.add_node(&word_text);
                    terminals.push((3, substrate));
                    // consume model name — store for later .MODEL lookup
                    if tok.peek() == tokenizer::TokenKind::Word {
                        let mname_tok = tok.advance();
                        let mname = std::str::from_utf8(mname_tok.text)
                            .unwrap_or("")
                            .to_ascii_lowercase();
                        if !mname.is_empty() {
                            device_model_name = Some(mname);
                        }
                    }
                } else {
                    // word_text was the model name (no 4th terminal follows)
                    if !word_text.is_empty() {
                        device_model_name = Some(word_text);
                    }
                }
            }
            parse_kv_pairs(tok, &mut params);
            tok.skip_line();
        }

        // ── Subcircuit instance: X ─────────────────────────────────────────
        b'x' => {
            // Xname node1 node2 ... nodeN subckt_name [param=value ...]
            // Read all word/number tokens; the last bare word before any kv pair
            // is the subckt_name. Store all preceding tokens as terminals.
            // We read tokens into a buffer, then assign the last one as subckt.
            let mut words: Vec<String> = Vec::new();

            loop {
                match tok.peek() {
                    tokenizer::TokenKind::Word => {
                        // Peek two tokens ahead to detect a kv pair (word '=' value).
                        // We can't easily double-peek with the current tokenizer API,
                        // so consume the word first, then check for '='.
                        let word_tok = tok.advance();
                        let word_text = std::str::from_utf8(word_tok.text)
                            .unwrap_or("")
                            .to_ascii_lowercase();
                        // Check if this is the start of a kv pair (word followed by '=')
                        if tok.peek() == tokenizer::TokenKind::Equals {
                            // This is "key=value" — consume '=' and value, store in params
                            tok.advance(); // consume '='
                            let value = parse_si_value(tok);
                            params.set(&word_text, value);
                        } else {
                            // Plain word — could be a node name or subckt_name
                            words.push(word_text);
                        }
                    }
                    tokenizer::TokenKind::Number => {
                        // Numeric node names
                        let token = tok.advance();
                        let name = std::str::from_utf8(token.text).unwrap_or("0");
                        words.push(name.to_string());
                    }
                    tokenizer::TokenKind::Newline
                    | tokenizer::TokenKind::Eof
                    | tokenizer::TokenKind::Comment => break,
                    _ => {
                        tok.advance();
                        break;
                    }
                }
            }

            // The last word is the subckt_name; all preceding words are terminals.
            // Terminals: assign pin indices 0..N-1.
            // Record the subckt name and terminal NodeIds for later flattening.
            if let Some((last, rest)) = words.split_last() {
                // Store the subckt name for SubcktCall registration below.
                x_subckt_name = Some(last.clone());
                // Sentinel param so existing tests expecting "subckt" key still pass.
                params.set("subckt", 1.0);

                for (pin, node_name) in rest.iter().enumerate() {
                    let node_id = circuit.add_node(node_name);
                    terminals.push((pin as u8, node_id));
                    x_terminal_nodes.push(node_id);
                }
            }
            tok.skip_line();
        }

        // ── VCVS: E (4 terminals: n+, n-, nc+, nc-; param: gain) ──────────
        b'e' => {
            // Ename n+ n- nc+ nc- gain
            // Ename n+ n- POLY(n) ctrl_pairs... coeffs...
            // Ename n+ n- TABLE {expr} = (x,y) (x,y) ...
            // Ename n+ n- VALUE={expr}
            let np = parse_node(tok, circuit);
            let nm = parse_node(tok, circuit);
            terminals.push((0, np));
            terminals.push((1, nm));

            // Peek at next token to detect POLY / TABLE / VALUE or standard 4-terminal form.
            let next_word = if tok.peek() == tokenizer::TokenKind::Word {
                let t = tok.advance();
                std::str::from_utf8(t.text).unwrap_or("").to_ascii_lowercase()
            } else {
                String::new()
            };

            if next_word.starts_with("poly") {
                // POLY(n) syntax: E1 out 0 POLY(2) in1 0 in2 0 0 1 1
                let degree = parse_poly_degree(&next_word, tok);
                params.set("poly_degree", degree as f64);
                // Parse 2*degree control nodes
                for i in 0..(degree * 2) {
                    let node = parse_node(tok, circuit);
                    let pin = (2 + i) as u8;
                    terminals.push((pin, node));
                }
                // Parse polynomial coefficients
                let mut coeff_idx = 0u32;
                loop {
                    match tok.peek() {
                        tokenizer::TokenKind::Number
                        | tokenizer::TokenKind::Minus
                        | tokenizer::TokenKind::Plus => {
                            let c = parse_si_value(tok);
                            params.set(&format!("poly_c{coeff_idx}"), c);
                            coeff_idx += 1;
                        }
                        tokenizer::TokenKind::Newline
                        | tokenizer::TokenKind::Eof
                        | tokenizer::TokenKind::Comment => break,
                        _ => { tok.advance(); }
                    }
                }
                params.set("poly_ncoeffs", coeff_idx as f64);
                // For POLY(1) set gain = poly_c1 (linear coefficient) for compat
                if degree == 1 {
                    if let Some(c1) = params.get("poly_c1") {
                        params.set("gain", c1);
                    }
                }
            } else if next_word == "table" {
                // TABLE {expr} = (x0,y0) (x1,y1) ...
                params.set("table", 1.0);
                // Parse the control expression (likely in braces)
                if tok.peek() == tokenizer::TokenKind::BraceExpr {
                    let t = tok.advance();
                    let expr_str = std::str::from_utf8(t.text).unwrap_or("0");
                    let inner = expr_str.trim()
                        .trim_start_matches('{')
                        .trim_end_matches('}')
                        .trim();
                    // Extract control node from V(node) pattern
                    let inner_lower = inner.to_ascii_lowercase();
                    if inner_lower.starts_with("v(") && inner_lower.ends_with(')') {
                        let node_name = &inner[2..inner.len()-1];
                        let ctrl_node = circuit.add_node(&node_name.to_ascii_lowercase());
                        terminals.push((2, ctrl_node));
                        terminals.push((3, NodeId::GROUND));
                    }
                }
                // Skip optional '='
                if tok.peek() == tokenizer::TokenKind::Equals {
                    tok.advance();
                }
                // Parse (x,y) pairs
                let mut pair_idx = 0u32;
                loop {
                    match tok.peek() {
                        tokenizer::TokenKind::LeftParen => {
                            tok.advance(); // consume '('
                            let x = parse_si_value(tok);
                            // skip optional comma
                            if tok.peek() == tokenizer::TokenKind::Comma {
                                tok.advance();
                            }
                            let y = parse_si_value(tok);
                            if tok.peek() == tokenizer::TokenKind::RightParen {
                                tok.advance();
                            }
                            params.set(&format!("table_x{pair_idx}"), x);
                            params.set(&format!("table_y{pair_idx}"), y);
                            pair_idx += 1;
                        }
                        tokenizer::TokenKind::Newline
                        | tokenizer::TokenKind::Eof
                        | tokenizer::TokenKind::Comment => break,
                        _ => { tok.advance(); }
                    }
                }
                params.set("table_pairs", pair_idx as f64);
            } else if next_word == "value" {
                // VALUE={expr}
                if tok.peek() == tokenizer::TokenKind::Equals {
                    tok.advance();
                }
                let val = parse_expr_or_si_value(tok, circuit);
                params.set("gain", val);
                tok.skip_line();
            } else if !next_word.is_empty() {
                // Standard form: word we consumed is nc+ node name
                let ncp = circuit.add_node(&next_word);
                let ncm = parse_node(tok, circuit);
                terminals.push((2, ncp));
                terminals.push((3, ncm));
                let gain = parse_si_value(tok);
                params.set("gain", gain);
                tok.skip_line();
            } else {
                // next token was not a Word — numeric node names (e.g. E1 out 0 1 0 10)
                let ncp = parse_node(tok, circuit);
                let ncm = parse_node(tok, circuit);
                terminals.push((2, ncp));
                terminals.push((3, ncm));
                let gain = parse_si_value(tok);
                params.set("gain", gain);
                tok.skip_line();
            }
        }

        // ── VCCS: G (4 terminals: n+, n-, nc+, nc-; param: gain) ──────────
        b'g' => {
            // Gname n+ n- nc+ nc- gain
            // Gname n+ n- POLY(n) ctrl_pairs... coeffs...
            // Gname n+ n- TABLE {expr} = (x,y) (x,y) ...
            // Gname n+ n- VALUE={expr}
            let np = parse_node(tok, circuit);
            let nm = parse_node(tok, circuit);
            terminals.push((0, np));
            terminals.push((1, nm));

            // Peek to detect POLY or standard form.
            let next_word = if tok.peek() == tokenizer::TokenKind::Word {
                let t = tok.advance();
                std::str::from_utf8(t.text).unwrap_or("").to_ascii_lowercase()
            } else {
                String::new()
            };

            if next_word.starts_with("poly") {
                let degree = parse_poly_degree(&next_word, tok);
                params.set("poly_degree", degree as f64);
                for i in 0..(degree * 2) {
                    let node = parse_node(tok, circuit);
                    let pin = (2 + i) as u8;
                    terminals.push((pin, node));
                }
                let mut coeff_idx = 0u32;
                loop {
                    match tok.peek() {
                        tokenizer::TokenKind::Number
                        | tokenizer::TokenKind::Minus
                        | tokenizer::TokenKind::Plus => {
                            let c = parse_si_value(tok);
                            params.set(&format!("poly_c{coeff_idx}"), c);
                            coeff_idx += 1;
                        }
                        tokenizer::TokenKind::Newline
                        | tokenizer::TokenKind::Eof
                        | tokenizer::TokenKind::Comment => break,
                        _ => { tok.advance(); }
                    }
                }
                params.set("poly_ncoeffs", coeff_idx as f64);
                if degree == 1 {
                    if let Some(c1) = params.get("poly_c1") {
                        params.set("gain", c1);
                    }
                }
            } else if next_word == "table" {
                // TABLE {expr} = (x0,y0) (x1,y1) ...
                params.set("table", 1.0);
                // Parse the control expression (likely in braces)
                if tok.peek() == tokenizer::TokenKind::BraceExpr {
                    let t = tok.advance();
                    let expr_str = std::str::from_utf8(t.text).unwrap_or("0");
                    let inner = expr_str.trim()
                        .trim_start_matches('{')
                        .trim_end_matches('}')
                        .trim();
                    // Extract control node from V(node) pattern
                    let inner_lower = inner.to_ascii_lowercase();
                    if inner_lower.starts_with("v(") && inner_lower.ends_with(')') {
                        let node_name = &inner[2..inner.len()-1];
                        let ctrl_node = circuit.add_node(&node_name.to_ascii_lowercase());
                        terminals.push((2, ctrl_node));
                        terminals.push((3, NodeId::GROUND));
                    }
                }
                // Skip optional '='
                if tok.peek() == tokenizer::TokenKind::Equals {
                    tok.advance();
                }
                // Parse (x,y) pairs
                let mut pair_idx = 0u32;
                loop {
                    match tok.peek() {
                        tokenizer::TokenKind::LeftParen => {
                            tok.advance(); // consume '('
                            let x = parse_si_value(tok);
                            // skip optional comma
                            if tok.peek() == tokenizer::TokenKind::Comma {
                                tok.advance();
                            }
                            let y = parse_si_value(tok);
                            if tok.peek() == tokenizer::TokenKind::RightParen {
                                tok.advance();
                            }
                            params.set(&format!("table_x{pair_idx}"), x);
                            params.set(&format!("table_y{pair_idx}"), y);
                            pair_idx += 1;
                        }
                        tokenizer::TokenKind::Newline
                        | tokenizer::TokenKind::Eof
                        | tokenizer::TokenKind::Comment => break,
                        _ => { tok.advance(); }
                    }
                }
                params.set("table_pairs", pair_idx as f64);
            } else if next_word == "value" {
                // VALUE={expr}
                if tok.peek() == tokenizer::TokenKind::Equals {
                    tok.advance();
                }
                let val = parse_expr_or_si_value(tok, circuit);
                params.set("gain", val);
                tok.skip_line();
            } else if !next_word.is_empty() {
                // Standard form: word is nc+ node name
                let ncp = circuit.add_node(&next_word);
                let ncm = parse_node(tok, circuit);
                terminals.push((2, ncp));
                terminals.push((3, ncm));
                let gain = parse_si_value(tok);
                params.set("gain", gain);
                tok.skip_line();
            } else {
                // Numeric node names
                let ncp = parse_node(tok, circuit);
                let ncm = parse_node(tok, circuit);
                terminals.push((2, ncp));
                terminals.push((3, ncm));
                let gain = parse_si_value(tok);
                params.set("gain", gain);
                tok.skip_line();
            }
        }

        // ── CCCS: F (2 terminals: n+, n-; vsense word; param: gain) ───────
        b'f' => {
            // Fname n+ n- Vsense_name gain
            // Fname n+ n- POLY(n) Vsense1 Vsense2 ... coeffs...
            let np = parse_node(tok, circuit);
            let nm = parse_node(tok, circuit);
            terminals.push((0, np));
            terminals.push((1, nm));

            let next_word = if tok.peek() == tokenizer::TokenKind::Word {
                let t = tok.advance();
                std::str::from_utf8(t.text).unwrap_or("").to_ascii_lowercase()
            } else {
                String::new()
            };

            if next_word.starts_with("poly") {
                let degree = parse_poly_degree(&next_word, tok);
                params.set("poly_degree", degree as f64);
                // Skip vsense names (degree of them)
                for _ in 0..degree {
                    if tok.peek() == tokenizer::TokenKind::Word {
                        tok.advance();
                    }
                }
                let mut coeff_idx = 0u32;
                loop {
                    match tok.peek() {
                        tokenizer::TokenKind::Number
                        | tokenizer::TokenKind::Minus
                        | tokenizer::TokenKind::Plus => {
                            let c = parse_si_value(tok);
                            params.set(&format!("poly_c{coeff_idx}"), c);
                            coeff_idx += 1;
                        }
                        tokenizer::TokenKind::Newline
                        | tokenizer::TokenKind::Eof
                        | tokenizer::TokenKind::Comment => break,
                        _ => { tok.advance(); }
                    }
                }
                params.set("poly_ncoeffs", coeff_idx as f64);
                if degree == 1 {
                    if let Some(c1) = params.get("poly_c1") {
                        params.set("gain", c1);
                    }
                }
            } else {
                // Standard form: word is Vsense name (skip it)
                let gain = parse_si_value(tok);
                params.set("gain", gain);
                tok.skip_line();
            }
        }

        // ── CCVS: H (2 terminals: n+, n-; vsense word; param: transresistance) ─
        b'h' => {
            // Hname n+ n- Vsense_name transresistance
            // Hname n+ n- POLY(n) Vsense1 ... coeffs...
            let np = parse_node(tok, circuit);
            let nm = parse_node(tok, circuit);
            terminals.push((0, np));
            terminals.push((1, nm));

            let next_word = if tok.peek() == tokenizer::TokenKind::Word {
                let t = tok.advance();
                std::str::from_utf8(t.text).unwrap_or("").to_ascii_lowercase()
            } else {
                String::new()
            };

            if next_word.starts_with("poly") {
                let degree = parse_poly_degree(&next_word, tok);
                params.set("poly_degree", degree as f64);
                for _ in 0..degree {
                    if tok.peek() == tokenizer::TokenKind::Word {
                        tok.advance();
                    }
                }
                let mut coeff_idx = 0u32;
                loop {
                    match tok.peek() {
                        tokenizer::TokenKind::Number
                        | tokenizer::TokenKind::Minus
                        | tokenizer::TokenKind::Plus => {
                            let c = parse_si_value(tok);
                            params.set(&format!("poly_c{coeff_idx}"), c);
                            coeff_idx += 1;
                        }
                        tokenizer::TokenKind::Newline
                        | tokenizer::TokenKind::Eof
                        | tokenizer::TokenKind::Comment => break,
                        _ => { tok.advance(); }
                    }
                }
                params.set("poly_ncoeffs", coeff_idx as f64);
                if degree == 1 {
                    if let Some(c1) = params.get("poly_c1") {
                        params.set("transresistance", c1);
                    }
                }
            } else {
                // Standard form: word is Vsense name (skip it)
                let transresistance = parse_si_value(tok);
                params.set("transresistance", transresistance);
                tok.skip_line();
            }
        }

        // ── Behavioral source: B ──────────────────────────────────────────
        b'b' => {
            // Bname n+ n- V={expr}  or  Bname n+ n- I={expr}
            let np = parse_node(tok, circuit);
            let nm = parse_node(tok, circuit);
            terminals.push((0, np));
            terminals.push((1, nm));

            // Next token should be a word "V" or "I" followed by "=" and an expression.
            if tok.peek() == tokenizer::TokenKind::Word {
                let kw_tok = tok.advance();
                let kw = std::str::from_utf8(kw_tok.text)
                    .unwrap_or("")
                    .to_ascii_lowercase();
                // Consume '='
                if tok.peek() == tokenizer::TokenKind::Equals {
                    tok.advance();
                }
                // The expression may be wrapped in braces { } or be a plain value.
                // We store the presence as a sentinel (1.0) since ParamMap is f64-only.
                // For a numeric expression, also attempt to parse its value.
                let expr_val = if tok.peek() == tokenizer::TokenKind::LeftBrace {
                    tok.advance(); // consume '{'
                    let v = parse_si_value(tok);
                    // drain until '}'
                    loop {
                        match tok.peek() {
                            tokenizer::TokenKind::RightBrace
                            | tokenizer::TokenKind::Newline
                            | tokenizer::TokenKind::Eof => break,
                            _ => { tok.advance(); }
                        }
                    }
                    if tok.peek() == tokenizer::TokenKind::RightBrace {
                        tok.advance();
                    }
                    v
                } else {
                    parse_si_value(tok)
                };

                match kw.as_str() {
                    "v" => params.set("v_expr", expr_val),
                    "i" => params.set("i_expr", expr_val),
                    _ => {}
                }
            }
            tok.skip_line();
        }

        // ── JFET: J (3 terminals: D, G, S) ────────────────────────────────
        b'j' => {
            // Jname drain gate source model_name [param=value ...]
            let drain = parse_node(tok, circuit);
            let gate = parse_node(tok, circuit);
            let source = parse_node(tok, circuit);
            terminals.push((0, drain));
            terminals.push((1, gate));
            terminals.push((2, source));
            // model name — store for later .MODEL lookup
            if tok.peek() == tokenizer::TokenKind::Word {
                let mname_tok = tok.advance();
                let mname = std::str::from_utf8(mname_tok.text)
                    .unwrap_or("")
                    .to_ascii_lowercase();
                if !mname.is_empty() {
                    device_model_name = Some(mname);
                }
            }
            parse_kv_pairs(tok, &mut params);
            tok.skip_line();
        }

        // ── MESFET: Z (3 terminals: D, G, S) ───────────────────────────────
        b'z' => {
            // Zname drain gate source model_name [param=value ...]
            let drain = parse_node(tok, circuit);
            let gate = parse_node(tok, circuit);
            let source = parse_node(tok, circuit);
            terminals.push((0, drain));
            terminals.push((1, gate));
            terminals.push((2, source));
            // model name — store for later .MODEL lookup
            if tok.peek() == tokenizer::TokenKind::Word {
                let mname_tok = tok.advance();
                let mname = std::str::from_utf8(mname_tok.text)
                    .unwrap_or("")
                    .to_ascii_lowercase();
                if !mname.is_empty() {
                    device_model_name = Some(mname);
                }
            }
            parse_kv_pairs(tok, &mut params);
            tok.skip_line();
        }

        // ── Lossless T-line: T (4 terminals: n1+, n1-, n2+, n2-) ─────────────
        b't' => {
            // Tname n1+ n1- n2+ n2- [Z0=value TD=value ...]
            let np1 = parse_node(tok, circuit);
            let nm1 = parse_node(tok, circuit);
            let np2 = parse_node(tok, circuit);
            let nm2 = parse_node(tok, circuit);
            terminals.push((0, np1));
            terminals.push((1, nm1));
            terminals.push((2, np2));
            terminals.push((3, nm2));
            parse_kv_pairs(tok, &mut params);
            tok.skip_line();
        }

        // ── Lossy T-line (LTRA): O (4 terminals: n1+, n1-, n2+, n2-) ────────
        b'o' => {
            // Oname n1+ n1- n2+ n2- model_name [key=value ...]
            let n1 = parse_node(tok, circuit);
            let n2 = parse_node(tok, circuit);
            let n3 = parse_node(tok, circuit);
            let n4 = parse_node(tok, circuit);
            terminals.push((0, n1));
            terminals.push((1, n2));
            terminals.push((2, n3));
            terminals.push((3, n4));
            parse_kv_pairs(tok, &mut params);
            tok.skip_line();
        }

        // ── URC distributed RC line: U (3 terminals: n1, n2, ngnd) ───────────
        b'u' => {
            // Uname n1 n2 ngnd model_name [key=value ...]
            let n1 = parse_node(tok, circuit);
            let n2 = parse_node(tok, circuit);
            let ngnd = parse_node(tok, circuit);
            terminals.push((0, n1));
            terminals.push((1, n2));
            terminals.push((2, ngnd));
            parse_kv_pairs(tok, &mut params);
            tok.skip_line();
        }

        // ── Voltage-controlled switch: S (4 terminals: n+, n-, nc+, nc-) ──
        b's' => {
            // Sname n+ n- nc+ nc- model_name [ON|OFF]
            let np = parse_node(tok, circuit);
            let nm = parse_node(tok, circuit);
            let ncp = parse_node(tok, circuit);
            let ncm = parse_node(tok, circuit);
            terminals.push((0, np));
            terminals.push((1, nm));
            terminals.push((2, ncp));
            terminals.push((3, ncm));
            if tok.peek() == tokenizer::TokenKind::Word {
                let mname_tok = tok.advance();
                let mname = std::str::from_utf8(mname_tok.text)
                    .unwrap_or("")
                    .to_ascii_lowercase();
                if !mname.is_empty() {
                    device_model_name = Some(mname);
                }
            }
            parse_kv_pairs(tok, &mut params);
            tok.skip_line();
        }

        // ── XSPICE A-element: A (variable ports + model name) ────────────
        b'a' => {
            // Aname [port_group]... model_name
            // Aname (port_group)... model_name
            //
            // Ports can be wrapped in () for scalar analog ports, [] for
            // vector digital ports, or bare node names separated by spaces.
            // The last bare word on the line (that is not inside brackets)
            // is the model name.
            //
            // We collect all analog node names as terminals (for MNA node
            // allocation) and store the model name for post-parse digital
            // net construction.
            let mut port_nodes: Vec<String> = Vec::new();

            loop {
                match tok.peek() {
                    tokenizer::TokenKind::Newline
                    | tokenizer::TokenKind::Eof
                    | tokenizer::TokenKind::Comment => break,

                    tokenizer::TokenKind::LeftParen => {
                        // Scalar analog port group: (node1)
                        tok.advance(); // consume '('
                        while tok.peek() != tokenizer::TokenKind::RightParen
                            && tok.peek() != tokenizer::TokenKind::Newline
                            && tok.peek() != tokenizer::TokenKind::Eof
                        {
                            if tok.peek() == tokenizer::TokenKind::Word
                                || tok.peek() == tokenizer::TokenKind::Number
                            {
                                let node_tok = tok.advance();
                                let node_name = std::str::from_utf8(node_tok.text)
                                    .unwrap_or("0")
                                    .to_ascii_lowercase();
                                port_nodes.push(node_name);
                            } else {
                                tok.advance(); // skip commas etc.
                            }
                        }
                        if tok.peek() == tokenizer::TokenKind::RightParen {
                            tok.advance(); // consume ')'
                        }
                    }

                    tokenizer::TokenKind::Word => {
                        // Could be a bracket '[', a bare node, or the model name.
                        let token = tok.advance();
                        let text = std::str::from_utf8(token.text)
                            .unwrap_or("")
                            .to_ascii_lowercase();

                        if text == "[" {
                            // Vector digital port group: [node1 node2 ...]
                            while tok.peek() != tokenizer::TokenKind::Newline
                                && tok.peek() != tokenizer::TokenKind::Eof
                            {
                                let inner = tok.advance();
                                let inner_text = std::str::from_utf8(inner.text)
                                    .unwrap_or("");
                                if inner_text == "]" {
                                    break;
                                }
                                let node_name = inner_text.to_ascii_lowercase();
                                if !node_name.is_empty() {
                                    port_nodes.push(node_name);
                                }
                            }
                        } else {
                            // Bare word — could be a node name or the model name.
                            // We tentatively collect it; if it turns out to be the
                            // last word before EOL, we treat it as the model name.
                            port_nodes.push(text);
                        }
                    }

                    _ => {
                        // Skip unexpected tokens (e.g. ']' appearing as non-Word)
                        let token = tok.advance();
                        let text = std::str::from_utf8(token.text).unwrap_or("");
                        if text == "[" {
                            // Vector port group via non-Word token
                            while tok.peek() != tokenizer::TokenKind::Newline
                                && tok.peek() != tokenizer::TokenKind::Eof
                            {
                                let inner = tok.advance();
                                let inner_text = std::str::from_utf8(inner.text)
                                    .unwrap_or("");
                                if inner_text == "]" {
                                    break;
                                }
                                let node_name = inner_text.to_ascii_lowercase();
                                if !node_name.is_empty() {
                                    port_nodes.push(node_name);
                                }
                            }
                        }
                        // otherwise skip
                    }
                }
            }

            // The last collected word is the model name; everything before
            // it is a port node.
            if let Some(model_name) = port_nodes.pop() {
                device_model_name = Some(model_name);
            }

            // Register remaining port nodes as terminals.
            for (pin, node_name) in port_nodes.iter().enumerate() {
                let nid = circuit.add_node(node_name);
                terminals.push((pin as u8, nid));
            }

            tok.skip_line();
        }

        // ── Mutual inductance: K (not a device — coupling between inductors) ─
        b'k' => {
            // K<name> L1_name L2_name coupling_coefficient
            // Parse the two inductor names and the coupling value, then store
            // for post-parse resolution (inductors may be forward-declared).
            let l1_name = if tok.peek() == tokenizer::TokenKind::Word {
                tok.consume_word().to_ascii_lowercase()
            } else {
                tok.skip_line();
                return Err(ParseError::Syntax {
                    line: 0,
                    msg: format!("K-element '{name}': expected L1 inductor name"),
                });
            };
            let l2_name = if tok.peek() == tokenizer::TokenKind::Word {
                tok.consume_word().to_ascii_lowercase()
            } else {
                tok.skip_line();
                return Err(ParseError::Syntax {
                    line: 0,
                    msg: format!("K-element '{name}': expected L2 inductor name"),
                });
            };
            let k_value = parse_si_value(tok);
            tok.skip_line();
            pending_k_elements.push((l1_name, l2_name, k_value));
            return Ok(());
        }

        // ── Unknown element type — fail rather than silently skip ───────────
        _ => {
            tok.skip_line();
            return Err(ParseError::Syntax {
                line: 0,
                msg: format!(
                    "unsupported element '{name}' (prefix '{}')",
                    first as char
                ),
            });
        }
    }

    let dev_id = DeviceId::new(circuit.devices().len() as u32);
    let mut device = DeviceInstance::new(dev_id, &name, kind, &terminals);
    device.params = params.clone();
    circuit.add_device(device);

    // Record model association for post-parse merge step.
    if let Some(model_name) = device_model_name {
        pending_models.push((dev_id, model_name, element_line));
    }

    // Register a SubcktCall for X-instance flattening.
    if let Some(sname) = x_subckt_name {
        circuit.add_subckt_call(SubcktCall {
            device_id: dev_id,
            instance_name: name.to_lowercase(),
            subckt_name: sname,
            terminal_nodes: x_terminal_nodes,
            params,
        });
    }

    Ok(())
}


// ---------------------------------------------------------------------------
// .PARAM expression evaluation
// ---------------------------------------------------------------------------

/// Evaluate all collected raw `.PARAM` entries and store results in `circuit.global_params`.
///
/// 1. Topologically sorts the params so that dependencies are evaluated first.
/// 2. Builds an `ExprEval` incrementally as each param is resolved.
/// 3. Stores the final `f64` value via `circuit.set_global_param`.
///
/// Returns an `ExprError` if a circular dependency or undefined reference is found.
fn evaluate_raw_params(
    raw_params: &[(String, String)],
    func_defs: &[(String, Vec<String>, String)],
    circuit: &mut Circuit,
) -> Result<(), incspice_core::ExprError> {
    if raw_params.is_empty() {
        return Ok(());
    }

    // Topologically sort so dependencies come first.
    let order = topo_sort_params(raw_params)?;

    // Build the evaluator incrementally.
    let mut eval = ExprEval::new();

    // Register user-defined functions
    for (name, params, body) in func_defs {
        eval.set_user_func(name, params.clone(), body.clone());
    }

    for idx in order {
        let (name, raw_expr) = &raw_params[idx];
        let value = eval.eval(raw_expr)?;
        eval.set_var(name, value);
        circuit.set_global_param(name, value);
    }

    Ok(())
}

// ---------------------------------------------------------------------------
// Subcircuit flattening
// ---------------------------------------------------------------------------

/// Flatten all pending X-instance calls in `circuit` by re-parsing each
/// `.SUBCKT` body and inlining the resulting devices with renamed nodes and
/// device names.
///
/// This function lives in the `netlist` crate (not `core`) because it needs
/// to re-parse body bytes using the tokenizer owned by this crate.
///
/// # Algorithm
/// For each `SubcktCall` recorded during parsing:
/// 1. Look up the `SubcktDef` by name.
/// 2. Parse the body bytes into a temporary mini-`Circuit`.
/// 3. Build a port-name → instance-NodeId mapping.
/// 4. For each device in the mini-circuit:
///    a. Map its terminal NodeIds through the port map (if port) or create
///       a new prefixed internal node (if internal).
///    b. Add the device with a prefixed name (`<instance>_<devname>`).
/// 5. Remove the placeholder X-device.
/// 6. Register any nested X-calls from the mini-circuit for further passes.
///
/// The process repeats (up to `MAX_DEPTH` passes) to handle recursive subckts.
fn flatten_subcircuits(circuit: &mut Circuit) -> Result<(), ParseError> {
    use std::collections::HashMap as AHashMap;
    use incspice_core::{DeviceInstance, NodeId, SubcktCall};

    const MAX_DEPTH: usize = 64;

    for _depth in 0..MAX_DEPTH {
        if circuit.subckt_calls.is_empty() {
            return Ok(());
        }

        // Drain the current batch of pending calls.
        let calls: Vec<SubcktCall> = std::mem::take(&mut circuit.subckt_calls);

        for call in calls {
            // Look up definition — clone to avoid borrow conflict.
            let def = match circuit.subckt_defs.get(&call.subckt_name) {
                Some(d) => d.clone(),
                None => {
                    // Unknown subckt — remove placeholder and continue.
                    let x_lower = call.instance_name.to_lowercase();
                    if let Some(xid) = circuit.find_device_id(&x_lower) {
                        circuit.remove_device(xid);
                    }
                    continue;
                }
            };

            // Validate pin count matches definition.
            let expected = def.terminals.len();
            let actual = call.terminal_nodes.len();
            if actual != expected {
                return Err(ParseError::Syntax {
                    line: 0,
                    msg: format!(
                        "subcircuit '{}' instance '{}' has {} pins, but definition expects {} pins (ports: {:?})",
                        call.subckt_name, call.instance_name, actual, expected, def.terminals
                    ),
                });
            }

            // Build port-name → instance NodeId mapping.
            // def.terminals[i] → call.terminal_nodes[i]
            let mut port_map: AHashMap<String, NodeId> = AHashMap::new();
            for (port_name, &node_id) in def.terminals.iter().zip(call.terminal_nodes.iter()) {
                port_map.insert(port_name.to_lowercase(), node_id);
            }

            // Re-parse the body bytes into a temporary mini-circuit.
            // Prepend a dummy title so the parser's skip_title works.
            let mut body_bytes: Vec<u8> = b"subckt_body
".to_vec();
            body_bytes.extend_from_slice(&def.body);

            // Parse the mini-circuit. If parsing fails, skip this call.
            let mini_netlist = match SpiceParser::parse_netlist(&body_bytes) {
                Ok(n) => n,
                Err(_) => {
                    let x_lower = call.instance_name.to_lowercase();
                    if let Some(xid) = circuit.find_device_id(&x_lower) {
                        circuit.remove_device(xid);
                    }
                    continue;
                }
            };
            let mini = mini_netlist.circuit;

            // Build NodeId → node name map for the mini-circuit.
            let mut mini_node_name: AHashMap<NodeId, String> = AHashMap::new();
            for node in mini.nodes().iter() {
                mini_node_name.insert(node.id, node.name.clone());
            }

            let instance_prefix = call.instance_name.to_lowercase();

            // Build mini NodeId → main NodeId map.
            let mut node_id_map: AHashMap<NodeId, NodeId> = AHashMap::new();
            node_id_map.insert(NodeId::GROUND, NodeId::GROUND);

            for (mini_id, mini_name) in &mini_node_name {
                if *mini_id == NodeId::GROUND {
                    continue;
                }
                let lower = mini_name.to_lowercase();
                if let Some(&mapped) = port_map.get(&lower) {
                    // Port node — map to the caller's node.
                    node_id_map.insert(*mini_id, mapped);
                } else if circuit.globals().iter().any(|g| g == &lower) {
                    // Global node — map to the top-level global node (no prefix).
                    let top_id = circuit.add_node(&lower);
                    node_id_map.insert(*mini_id, top_id);
                } else {
                    // Internal node — prefix with instance name.
                    let new_name = format!("{instance_prefix}_{lower}");
                    let top_id = circuit.add_node(&new_name);
                    node_id_map.insert(*mini_id, top_id);
                }
            }

            // Instantiate each non-X device from the mini-circuit.
            // (X devices are represented as SubcktCalls in mini.subckt_calls;
            //  they are re-queued for the next pass below.)
            for dev in mini.devices() {
                // Skip placeholder X devices — they are handled via subckt_calls.
                // Skip X-placeholder devices — they are handled via subckt_calls.
                if dev.params.get("subckt").is_some() {
                    continue;
                }

                let new_terminals: Vec<(u8, NodeId)> = dev
                    .terminals
                    .iter()
                    .map(|t| {
                        let mapped = node_id_map.get(&t.node).copied().unwrap_or(NodeId::GROUND);
                        (t.pin, mapped)
                    })
                    .collect();

                let new_name = format!("{}_{}", instance_prefix, dev.name.to_lowercase());
                let mut new_dev = DeviceInstance::new(
                    incspice_core::DeviceId::new(0), // reassigned by add_device
                    new_name,
                    dev.kind,
                    &new_terminals,
                );
                new_dev.params = dev.params.clone();
                // Apply instance-level param overrides.
                for (key, val) in call.params.iter() {
                    new_dev.params.set(key, val);
                }
                circuit.add_device(new_dev);
            }

            // Re-queue any nested X-calls from the mini-circuit.
            for mut ncall in mini.subckt_calls {
                // Remap terminal nodes through node_id_map.
                for node in ncall.terminal_nodes.iter_mut() {
                    if let Some(&mapped) = node_id_map.get(node) {
                        *node = mapped;
                    }
                }
                // Prefix the instance name with the parent instance prefix.
                let prefixed_name = format!("{}_{}", instance_prefix, ncall.instance_name);
                ncall.instance_name = prefixed_name.clone();
                // Find the X-placeholder device that was just added to the
                // main circuit (from the mini-circuit devices loop above).
                if let Some(main_id) = circuit.find_device_id(&prefixed_name) {
                    ncall.device_id = main_id;
                    circuit.subckt_calls.push(ncall);
                }
            }

            // Remove the placeholder X-device for this call.
            let x_lower = call.instance_name.to_lowercase();
            if let Some(x_id) = circuit.find_device_id(&x_lower) {
                circuit.remove_device(x_id);
            }
        }
    }

    if !circuit.subckt_calls.is_empty() {
        Err(ParseError::SubcircuitCycle(
            "flattening depth limit exceeded (possible cycle)".to_string(),
        ))
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(netlist: &str) -> Result<ParsedNetlist, ParseError> {
        SpiceParser::parse_str(netlist)
    }

    #[test]
    fn test_parse_resistor() {
        // Title line is skipped by the parser, so we need one.
        let netlist = "test title\nR1 vdd gnd 1k\n.end\n";
        let result = parse(netlist).unwrap();
        let circuit = &result.circuit;
        let dev = circuit.find_device("r1").unwrap();
        assert_eq!(dev.kind, DeviceKind::Resistor);
        assert_eq!(dev.terminal_count(), 2);
        // "vdd" node must exist
        let vdd = circuit.find_node("vdd").expect("vdd node");
        assert_eq!(dev.node(0), Some(vdd));
        assert_eq!(dev.node(1), Some(NodeId::GROUND));
        let r = dev.params.get("resistance").unwrap();
        assert!((r - 1000.0).abs() < 1e-9, "resistance should be 1k, got {r}");
    }

    #[test]
    fn test_parse_capacitor() {
        let netlist = "test\nC1 out gnd 1u\n.end\n";
        let result = parse(netlist).unwrap();
        let circuit = &result.circuit;
        let dev = circuit.find_device("c1").unwrap();
        assert_eq!(dev.kind, DeviceKind::Capacitor);
        assert_eq!(dev.terminal_count(), 2);
        let c = dev.params.get("capacitance").unwrap();
        assert!((c - 1e-6).abs() < 1e-15, "capacitance should be 1u, got {c}");
    }

    #[test]
    fn test_parse_inductor() {
        let netlist = "test\nL1 a b 10n\n.end\n";
        let result = parse(netlist).unwrap();
        let circuit = &result.circuit;
        let dev = circuit.find_device("l1").unwrap();
        assert_eq!(dev.kind, DeviceKind::Inductor);
        assert_eq!(dev.terminal_count(), 2);
        let l = dev.params.get("inductance").unwrap();
        assert!((l - 10e-9).abs() < 1e-20, "inductance should be 10n, got {l}");
    }

    #[test]
    fn test_parse_voltage_source_dc() {
        let netlist = "test\nVdd vdd gnd 5.0\n.end\n";
        let result = parse(netlist).unwrap();
        let circuit = &result.circuit;
        let dev = circuit.find_device("vdd").unwrap();
        assert_eq!(dev.kind, DeviceKind::VoltageSource);
        assert_eq!(dev.terminal_count(), 2);
        let dc = dev.params.get("dc").unwrap();
        assert!((dc - 5.0).abs() < 1e-12, "dc value should be 5.0, got {dc}");
    }

    #[test]
    fn test_parse_voltage_source_dc_keyword() {
        let netlist = "test\nV1 vp vn DC 3.3\n.end\n";
        let result = parse(netlist).unwrap();
        let circuit = &result.circuit;
        let dev = circuit.find_device("v1").unwrap();
        let dc = dev.params.get("dc").unwrap();
        assert!((dc - 3.3).abs() < 1e-12, "dc value should be 3.3, got {dc}");
    }

    #[test]
    fn test_parse_current_source_dc() {
        let netlist = "test\nI1 net1 gnd 2m\n.end\n";
        let result = parse(netlist).unwrap();
        let circuit = &result.circuit;
        let dev = circuit.find_device("i1").unwrap();
        assert_eq!(dev.kind, DeviceKind::CurrentSource);
        let dc = dev.params.get("dc").unwrap();
        assert!((dc - 2e-3).abs() < 1e-15, "dc should be 2m, got {dc}");
    }

    #[test]
    fn test_parse_diode() {
        let netlist = "test\nD1 anode cathode 1N4148\n.end\n";
        let result = parse(netlist).unwrap();
        let circuit = &result.circuit;
        let dev = circuit.find_device("d1").unwrap();
        assert_eq!(dev.kind, DeviceKind::Diode);
        assert_eq!(dev.terminal_count(), 2);
        let anode_id = circuit.find_node("anode").expect("anode node");
        let cathode_id = circuit.find_node("cathode").expect("cathode node");
        assert_eq!(dev.node(0), Some(anode_id));
        assert_eq!(dev.node(1), Some(cathode_id));
    }

    #[test]
    fn test_parse_multiple_elements() {
        let netlist = "voltage divider\nVs vdd gnd 5.0\nR1 vdd mid 1k\nR2 mid gnd 1k\n.end\n";
        let result = parse(netlist).unwrap();
        let circuit = &result.circuit;
        assert_eq!(circuit.devices().len(), 3);
        let r1 = circuit.find_device("r1").unwrap();
        let r2 = circuit.find_device("r2").unwrap();
        let vs = circuit.find_device("vs").unwrap();
        assert!((r1.params.get("resistance").unwrap() - 1000.0).abs() < 1.0);
        assert!((r2.params.get("resistance").unwrap() - 1000.0).abs() < 1.0);
        assert!((vs.params.get("dc").unwrap() - 5.0).abs() < 1e-9);
        // Nodes: gnd(0), vdd, mid (3 total = ground + 2)
        let mid = circuit.find_node("mid").expect("mid node");
        let vdd = circuit.find_node("vdd").expect("vdd node");
        assert_eq!(r1.node(0), Some(vdd));
        assert_eq!(r1.node(1), Some(mid));
        assert_eq!(r2.node(0), Some(mid));
        assert_eq!(r2.node(1), Some(NodeId::GROUND));
    }

    #[test]
    fn test_parse_resistor_si_suffixes() {
        let netlist = "test\nR1 a b 4.7k\nR2 c d 100\nR3 e f 2.2meg\n.end\n";
        let result = parse(netlist).unwrap();
        let circuit = &result.circuit;
        let r1 = circuit.find_device("r1").unwrap().params.get("resistance").unwrap();
        let r2 = circuit.find_device("r2").unwrap().params.get("resistance").unwrap();
        let r3 = circuit.find_device("r3").unwrap().params.get("resistance").unwrap();
        assert!((r1 - 4700.0).abs() < 0.01, "4.7k = 4700, got {r1}");
        assert!((r2 - 100.0).abs() < 0.01, "100 ohm, got {r2}");
        assert!((r3 - 2.2e6).abs() < 1.0, "2.2meg, got {r3}");
    }

    #[test]
    fn test_parse_voltage_source_pulse_fallback() {
        // Waveform sources should parse terminals and fall back dc=0.0
        let netlist = "test\nVpulse vp vn PULSE(0 5 0 1n 1n 5n 10n)\n.end\n";
        let result = parse(netlist).unwrap();
        let circuit = &result.circuit;
        let dev = circuit.find_device("vpulse").unwrap();
        assert_eq!(dev.kind, DeviceKind::VoltageSource);
        assert_eq!(dev.terminal_count(), 2);
        // dc defaults to 0.0 for waveform sources
        let dc = dev.params.get("dc").unwrap_or(0.0);
        assert!((dc - 0.0).abs() < 1e-12);
    }

    #[test]
    fn test_parse_mosfet() {
        let netlist = "test\nM1 drain gate source bulk NMOS W=1u L=0.18u\n.end\n";
        let circuit = parse(netlist).unwrap().circuit;
        let dev = circuit.find_device("m1").unwrap();
        assert_eq!(dev.kind, DeviceKind::MosfetN);
        assert_eq!(dev.terminal_count(), 4);
        // Check drain node (pin 0)
        let drain_id = circuit.find_node("drain").expect("drain node");
        let gate_id  = circuit.find_node("gate").expect("gate node");
        let src_id   = circuit.find_node("source").expect("source node");
        let bulk_id  = circuit.find_node("bulk").expect("bulk node");
        assert_eq!(dev.node(0), Some(drain_id));
        assert_eq!(dev.node(1), Some(gate_id));
        assert_eq!(dev.node(2), Some(src_id));
        assert_eq!(dev.node(3), Some(bulk_id));
        // W = 1u = 1e-6, L = 0.18u = 1.8e-7
        let w = dev.params.get("w").unwrap();
        let l = dev.params.get("l").unwrap();
        assert!((w - 1e-6).abs() < 1e-15, "W should be 1e-6, got {w}");
        assert!((l - 0.18e-6).abs() < 1e-20, "L should be 0.18e-6, got {l}");
    }

    #[test]
    fn test_parse_bjt() {
        let netlist = "test\nQ1 collector base emitter NPN\n.end\n";
        let circuit = parse(netlist).unwrap().circuit;
        let dev = circuit.find_device("q1").unwrap();
        assert_eq!(dev.kind, DeviceKind::BjtNpn);
        assert_eq!(dev.terminal_count(), 3);
        let c_id = circuit.find_node("collector").expect("collector node");
        let b_id = circuit.find_node("base").expect("base node");
        let e_id = circuit.find_node("emitter").expect("emitter node");
        assert_eq!(dev.node(0), Some(c_id));
        assert_eq!(dev.node(1), Some(b_id));
        assert_eq!(dev.node(2), Some(e_id));
    }

    #[test]
    fn test_parse_vcvs() {
        let netlist = "test\nE1 out gnd in gnd 10.0\n.end\n";
        let circuit = parse(netlist).unwrap().circuit;
        let dev = circuit.find_device("e1").unwrap();
        assert_eq!(dev.kind, DeviceKind::Vcvs);
        assert_eq!(dev.terminal_count(), 4);
        let gain = dev.params.get("gain").unwrap();
        assert!((gain - 10.0).abs() < 1e-12, "gain should be 10.0, got {gain}");
    }

    #[test]
    fn test_parse_subckt_instance() {
        // When the subcircuit definition is undefined, the X-placeholder is removed
        // by flatten_subcircuits.  The nodes referenced in the X-element should
        // still be created in the circuit.
        let netlist = "test\nXinv in out VDD GND inverter\n.end\n";
        let circuit = parse(netlist).unwrap().circuit;
        // After flattening of an unknown subcircuit, the placeholder X device
        // is removed, but the nodes must still exist.
        assert!(circuit.find_node("in").is_some(), "node 'in' should exist");
        assert!(circuit.find_node("out").is_some(), "node 'out' should exist");
        // The placeholder device is removed by the flattener.
        assert!(circuit.find_device("xinv").is_none(), "xinv placeholder should be removed");
    }

    #[test]
    fn test_parse_model_nmos() {
        let netlist = "test\n.MODEL NMOS1 NMOS (TOX=3e-9 VTH0=0.5)\n.end\n";
        let circuit = parse(netlist).unwrap().circuit;
        let model = circuit.find_model("nmos1").expect("model NMOS1 not found");
        assert_eq!(model.0, incspice_core::ModelKind::Nmos);
        let tox = model.1.get("tox").expect("TOX param not found");
        assert!((tox - 3e-9).abs() < 1e-18, "TOX should be 3e-9, got {tox}");
    }

    #[test]
    fn test_parse_param() {
        let netlist = "test\n.PARAM Rin=1k Cin=1u\n.end\n";
        let circuit = parse(netlist).unwrap().circuit;
        let rin = circuit.get_global_param("rin").expect("Rin param not found");
        let cin = circuit.get_global_param("cin").expect("Cin param not found");
        assert!((rin - 1000.0).abs() < 1e-9, "Rin should be 1000.0, got {rin}");
        assert!((cin - 1e-6).abs() < 1e-15, "Cin should be 1e-6, got {cin}");
    }

    /// Reproduces the func_macro fixture: param expressions used in device values.
    #[test]
    fn test_parse_param_expr_device_values() {
        let netlist = "test\n\
            .PARAM vdd_val=3.3\n\
            .PARAM r_val='1k*2'\n\
            V1 in 0 DC {vdd_val}\n\
            R1 in out {r_val}\n\
            R2 out 0 {r_val/2}\n\
            .OP\n\
            .end\n";
        let result = parse(netlist).unwrap();
        let circuit = &result.circuit;

        let vdd = circuit.get_global_param("vdd_val").expect("vdd_val not found");
        assert!((vdd - 3.3).abs() < 1e-12, "vdd_val should be 3.3, got {vdd}");
        let r = circuit.get_global_param("r_val").expect("r_val not found");
        assert!((r - 2000.0).abs() < 1e-9, "r_val should be 2000.0, got {r}");

        let v1 = circuit.find_device("v1").expect("V1 not found");
        let dc = v1.params.get("dc").unwrap_or(0.0);
        assert!((dc - 3.3).abs() < 1e-12, "V1 DC should be 3.3, got {dc}");

        let r1 = circuit.find_device("r1").expect("R1 not found");
        let r1_val = r1.params.get("resistance").unwrap_or(0.0);
        assert!((r1_val - 2000.0).abs() < 1e-9, "R1 resistance should be 2000, got {r1_val}");

        let r2 = circuit.find_device("r2").expect("R2 not found");
        let r2_val = r2.params.get("resistance").unwrap_or(0.0);
        assert!((r2_val - 1000.0).abs() < 1e-9, "R2 resistance should be 1000, got {r2_val}");
    }

    #[test]
    fn test_parse_tran_directive() {
        let netlist = "test\n.TRAN 1n 100n\n.end\n";
        let result = parse(netlist).unwrap();
        let analyses = &result.analyses;
        assert_eq!(analyses.len(), 1, "expected one analysis");
        match &analyses[0] {
            InternalAnalysisKind::Transient { tstep, tstop, tstart, .. } => {
                assert!((tstep - 1e-9).abs() < 1e-18, "tstep should be 1e-9, got {tstep}");
                assert!((tstop - 100e-9).abs() < 1e-16, "tstop should be 100e-9, got {tstop}");
                assert!((tstart - 0.0).abs() < 1e-18, "tstart should be 0.0, got {tstart}");
            }
            other => panic!("expected Transient, got {other:?}"),
        }
    }

    #[test]
    fn test_parse_ac_directive() {
        let netlist = "test\n.AC DEC 10 1 1MEG\n.end\n";
        let result = parse(netlist).unwrap();
        let analyses = &result.analyses;
        assert_eq!(analyses.len(), 1, "expected one analysis");
        match &analyses[0] {
            InternalAnalysisKind::Ac { sweep, fstart, fstop } => {
                match sweep {
                    AcSweepType::Dec(n) => assert_eq!(*n, 10, "npoints should be 10, got {n}"),
                    other => panic!("expected Dec sweep, got {other:?}"),
                }
                assert!((fstart - 1.0).abs() < 1e-9, "fstart should be 1.0, got {fstart}");
                assert!((fstop - 1e6).abs() < 1.0, "fstop should be 1e6, got {fstop}");
            }
            other => panic!("expected Ac, got {other:?}"),
        }
    }

    #[test]
    fn test_parse_subckt_definition() {
        let netlist = "test\n.SUBCKT inv in out VDD GND\nM1 out in VDD VDD PMOS\nM2 out in GND GND NMOS\n.ENDS inv\n.end\n";
        let result = parse(netlist).unwrap();
        let circuit = &result.circuit;
        let def = circuit.find_subckt_def("inv").expect("subckt 'inv' not stored");
        assert_eq!(def.name, "inv", "subckt name should be 'inv'");
        // 4 terminals: in, out, VDD, GND
        assert_eq!(def.terminals.len(), 4, "expected 4 terminals, got {}", def.terminals.len());
        assert_eq!(def.terminals[0], "in");
        assert_eq!(def.terminals[1], "out");
        assert_eq!(def.terminals[2], "VDD");
        assert_eq!(def.terminals[3], "GND");
    }

    #[test]
    fn test_parse_subckt_with_params() {
        let netlist = "test\n.SUBCKT myres a b R=1k\n.ENDS myres\n.end\n";
        let result = parse(netlist).unwrap();
        let circuit = &result.circuit;
        let def = circuit.find_subckt_def("myres").expect("subckt 'myres' not stored");
        assert_eq!(def.terminals.len(), 2, "expected 2 terminals");
        let r_default = def.params.get("r").expect("default param R not found");
        assert!((r_default - 1000.0).abs() < 1.0, "R default should be 1k, got {r_default}");
    }

    #[test]
    fn test_parse_options() {
        let netlist = "test\n.OPTIONS ABSTOL=1e-12 RELTOL=1e-6\n.end\n";
        let result = parse(netlist).unwrap();
        let opts = &result.options;
        let abstol = opts.abstol.expect("abstol not set");
        let reltol = opts.reltol.expect("reltol not set");
        assert!((abstol - 1e-12).abs() < 1e-20, "ABSTOL should be 1e-12, got {abstol}");
        assert!((reltol - 1e-6).abs() < 1e-15, "RELTOL should be 1e-6, got {reltol}");
    }

    #[test]
    fn test_parse_options_extra() {
        let netlist = "test\n.OPTIONS ITL1=200 TRTOL=3.5\n.end\n";
        let result = parse(netlist).unwrap();
        let opts = &result.options;
        let itl1 = opts.extras.get("itl1").copied().expect("itl1 not in extras");
        assert!((itl1 - 200.0).abs() < 1.0, "ITL1 should be 200, got {itl1}");
        let trtol = opts.extras.get("trtol").copied().expect("trtol not in extras");
        assert!((trtol - 3.5).abs() < 1e-9, "TRTOL should be 3.5, got {trtol}");
    }

    #[test]
    fn test_parse_global_node() {
        let netlist = "test\n.GLOBAL VDD GND\n.end\n";
        let result = parse(netlist).unwrap();
        let circuit = &result.circuit;
        let globals = circuit.globals();
        assert!(globals.contains(&"vdd".to_string()), "VDD should be in globals");
        assert!(globals.contains(&"gnd".to_string()), "GND should be in globals");
    }

    #[test]
    fn test_parse_temp_directive() {
        let netlist = "test\n.TEMP 27\n.end\n";
        let result = parse(netlist).unwrap();
        let circuit = &result.circuit;
        let temps = circuit.temperatures();
        assert_eq!(temps.len(), 1, "expected 1 temperature");
        // 27°C = 300.15 K
        assert!((temps[0] - 300.15).abs() < 0.01, "27°C should be ~300.15 K, got {}", temps[0]);
    }

    #[test]
    fn test_parse_save_print_plot_skip() {
        // These directives should not cause errors — they are skipped.
        let netlist = "test\n.SAVE V(out)\n.PRINT TRAN V(out) I(R1)\n.PLOT DC V(n1)\n.end\n";
        let result = parse(netlist);
        assert!(result.is_ok(), "SAVE/PRINT/PLOT should not cause parse errors");
    }

    #[test]
    fn test_parse_subckt_body_preserved() {
        // Body bytes of the subckt definition should be non-empty.
        let netlist = "test\n.SUBCKT inv in out VDD GND\nM1 out in VDD VDD PMOS\n.ENDS\n.end\n";
        let result = parse(netlist).unwrap();
        let circuit = &result.circuit;
        let def = circuit.find_subckt_def("inv").expect("subckt 'inv' not stored");
        assert!(!def.body.is_empty(), "subckt body should be non-empty");
    }

    // ── .MODEL merge tests ────────────────────────────────────────────────────

    #[test]
    fn test_model_params_merged_into_mosfet() {
        let netlist = "test\n.MODEL NMOS1 NMOS LEVEL=3 VTH0=0.4 TOX=8e-9\nM1 d g s b NMOS1 W=1u L=0.1u\n.END\n";
        let result = parse(netlist).unwrap();
        let circuit = &result.circuit;
        let dev = circuit.find_device("m1").expect("M1 not found");
        // DeviceKind should be MosfetN3 (LEVEL=3 NMOS)
        assert_eq!(dev.kind, DeviceKind::MosfetN3, "LEVEL=3 NMOS should map to MosfetN3");
        // Model params should be present
        let vth0 = dev.params.get("vth0").expect("VTH0 missing after model merge");
        assert!((vth0 - 0.4).abs() < 1e-9, "VTH0 should be 0.4, got {vth0}");
        let tox = dev.params.get("tox").expect("TOX missing after model merge");
        assert!((tox - 8e-9).abs() < 1e-18, "TOX should be 8e-9, got {tox}");
        // Device-level params (W, L) should override / coexist
        let w = dev.params.get("w").expect("W missing");
        let l = dev.params.get("l").expect("L missing");
        assert!((w - 1e-6).abs() < 1e-15, "W should be 1e-6, got {w}");
        assert!((l - 0.1e-6).abs() < 1e-20, "L should be 0.1e-6, got {l}");
    }

    #[test]
    fn test_pmos_model_kind_set() {
        let netlist = "test\n.MODEL PMOD PMOS\nM2 d g s b PMOD W=2u L=0.5u\n.END\n";
        let result = parse(netlist).unwrap();
        let circuit = &result.circuit;
        let dev = circuit.find_device("m2").expect("M2 not found");
        assert_eq!(dev.kind, DeviceKind::MosfetP, "PMOS model should set MosfetP kind");
    }

    #[test]
    fn test_pmos_model_injects_pmos_param() {
        // After merging a PMOS .MODEL, the device params must contain pmos=1.0
        // so that MosfetLevel1/2/3/6::eval can detect polarity at evaluation time.
        let netlist = "test\n.MODEL PMOD PMOS (VTO=-0.7 KP=50u GAMMA=0.4 PHI=0.65)\nM1 out in vdd vdd PMOD W=20u L=1u\n.END\n";
        let result = parse(netlist).unwrap();
        let circuit = &result.circuit;
        let dev = circuit.find_device("m1").expect("M1 not found");
        assert_eq!(dev.kind, DeviceKind::MosfetP, "PMOS model should set MosfetP kind");
        let pmos = dev.params.get("pmos").expect("pmos=1.0 sentinel must be present after PMOS model merge");
        assert!((pmos - 1.0).abs() < 1e-9, "pmos param should be 1.0, got {pmos}");
        // NMOS device should NOT have the pmos flag set
        let nmos_netlist = "test\n.MODEL NMOD NMOS (VTO=0.7 KP=110u)\nM2 d g s b NMOD W=10u L=1u\n.END\n";
        let nmos_result = parse(nmos_netlist).unwrap();
        let nmos_dev = nmos_result.circuit.find_device("m2").expect("M2 not found");
        assert_eq!(nmos_dev.kind, DeviceKind::MosfetN);
        let nmos_pmos = nmos_dev.params.get("pmos");
        assert!(
            nmos_pmos.is_none() || (nmos_pmos.unwrap() - 0.0).abs() < 1e-9,
            "NMOS device should not have pmos=1, got {:?}",
            nmos_pmos
        );
    }

    #[test]
    fn test_pmos_inline_model_name_injects_pmos_param() {
        // When a subcircuit uses the bare model name "PMOS" (no .MODEL directive),
        // the inferred kind path must also inject pmos=1.0.
        let netlist = "test\nM1 out in vdd vdd PMOS W=20u L=1u\n.END\n";
        let result = parse(netlist).unwrap();
        let circuit = &result.circuit;
        let dev = circuit.find_device("m1").expect("M1 not found");
        assert_eq!(dev.kind, DeviceKind::MosfetP, "bare PMOS model name should set MosfetP kind");
        let pmos = dev.params.get("pmos").expect("pmos sentinel must be present for inline PMOS model name");
        assert!((pmos - 1.0).abs() < 1e-9, "pmos param should be 1.0, got {pmos}");
    }

    #[test]
    fn test_bsim4_level_kind() {
        let netlist = "test\n.MODEL NMOS4 NMOS LEVEL=14 VTH0=0.35\nM3 d g s b NMOS4 W=1u L=65n\n.END\n";
        let result = parse(netlist).unwrap();
        let circuit = &result.circuit;
        let dev = circuit.find_device("m3").expect("M3 not found");
        assert_eq!(dev.kind, DeviceKind::Bsim4N, "LEVEL=14 NMOS should map to Bsim4N");
        let vth0 = dev.params.get("vth0").expect("VTH0 missing");
        assert!((vth0 - 0.35).abs() < 1e-9, "VTH0 should be 0.35");
    }

    #[test]
    fn test_bjt_bf_from_model() {
        let netlist = "test\n.MODEL NPN1 NPN IS=1e-15 BF=150 NF=1.0 VAF=100\nQ1 c b e NPN1\n.END\n";
        let result = parse(netlist).unwrap();
        let circuit = &result.circuit;
        let dev = circuit.find_device("q1").expect("Q1 not found");
        assert_eq!(dev.kind, DeviceKind::BjtNpn, "NPN model should set BjtNpn kind");
        let bf = dev.params.get("bf").expect("BF missing after model merge");
        assert!((bf - 150.0).abs() < 1e-9, "BF should be 150, got {bf}");
        let vaf = dev.params.get("vaf").expect("VAF missing after model merge");
        assert!((vaf - 100.0).abs() < 1e-9, "VAF should be 100, got {vaf}");
    }

    #[test]
    fn test_pnp_model_kind_set() {
        let netlist = "test\n.MODEL PNP1 PNP IS=1e-14 BF=80\nQ2 c b e PNP1\n.END\n";
        let result = parse(netlist).unwrap();
        let circuit = &result.circuit;
        let dev = circuit.find_device("q2").expect("Q2 not found");
        assert_eq!(dev.kind, DeviceKind::BjtPnp, "PNP model should set BjtPnp kind");
        let bf = dev.params.get("bf").expect("BF missing");
        assert!((bf - 80.0).abs() < 1e-9, "BF should be 80, got {bf}");
    }

    #[test]
    fn test_diode_is_from_model() {
        let netlist = "test\n.MODEL D1N4148 D IS=2.52e-9 N=1.752 RS=0.568 BV=75 IBV=1e-7\nD1 anode cathode D1N4148\n.END\n";
        let result = parse(netlist).unwrap();
        let circuit = &result.circuit;
        let dev = circuit.find_device("d1").expect("D1 not found");
        assert_eq!(dev.kind, DeviceKind::Diode, "D model should keep Diode kind");
        let is = dev.params.get("is").expect("IS missing after model merge");
        assert!((is - 2.52e-9).abs() < 1e-18, "IS should be 2.52e-9, got {is}");
        let n = dev.params.get("n").expect("N missing");
        assert!((n - 1.752).abs() < 1e-9, "N should be 1.752, got {n}");
        let bv = dev.params.get("bv").expect("BV missing");
        assert!((bv - 75.0).abs() < 1e-9, "BV should be 75, got {bv}");
    }

    #[test]
    fn test_device_params_override_model_params() {
        // Device-level params should override model params after merge.
        let netlist = "test\n.MODEL MYMOD NMOS VTH0=0.5 W=5u\nM1 d g s b MYMOD W=1u L=0.18u\n.END\n";
        let result = parse(netlist).unwrap();
        let circuit = &result.circuit;
        let dev = circuit.find_device("m1").expect("M1 not found");
        // W=1u from device line should override W=5u from model
        let w = dev.params.get("w").expect("W missing");
        assert!((w - 1e-6).abs() < 1e-15, "device W=1u should override model W=5u, got {w}");
        // VTH0=0.5 from model should be present (device did not specify it)
        let vth0 = dev.params.get("vth0").expect("VTH0 missing");
        assert!((vth0 - 0.5).abs() < 1e-9, "VTH0 should come from model");
    }

    #[test]
    fn test_forward_declared_model() {
        // .MODEL can appear after the device line — post-parse merge handles this.
        let netlist = "test\nM1 d g s b NMOD W=1u L=0.1u\n.MODEL NMOD NMOS VTH0=0.4 KP=2e-4\n.END\n";
        let result = parse(netlist).unwrap();
        let circuit = &result.circuit;
        let dev = circuit.find_device("m1").expect("M1 not found");
        assert_eq!(dev.kind, DeviceKind::MosfetN, "NMOD NMOS should set MosfetN");
        let vth0 = dev.params.get("vth0").expect("VTH0 missing");
        assert!((vth0 - 0.4).abs() < 1e-9, "forward-declared model VTH0 should be merged");
    }

    #[test]
    fn test_unknown_model_leaves_device_unchanged() {
        // If no .MODEL definition exists, device should keep its original params/kind.
        let netlist = "test\nM1 d g s b NOMODEL W=1u L=0.1u\n.END\n";
        let result = parse(netlist).unwrap();
        let circuit = &result.circuit;
        let dev = circuit.find_device("m1").expect("M1 not found");
        // Kind should remain MosfetN (default from ELEMENT_PREFIX)
        assert_eq!(dev.kind, DeviceKind::MosfetN);
        // W and L should still be present
        assert!(dev.params.get("w").is_some());
    }
}

// ---------------------------------------------------------------------------
// .PARAM expression evaluation tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod param_tests {
    use super::*;

    /// Plain numeric `.PARAM` still works after the refactor.
    #[test]
    fn test_param_plain_numeric() {
        let netlist = b"test\n.PARAM x=2.5\n.END\n";
        let (circuit, _, _) = SpiceParser::parse_bytes(netlist).unwrap();
        let x = circuit.get_global_param("x").expect("param x missing");
        assert!((x - 2.5).abs() < 1e-12, "x should be 2.5, got {x}");
    }

    /// Arithmetic expression inside braces.
    #[test]
    fn test_param_arithmetic_expression() {
        let netlist = b"test\n.PARAM x={5.0/2}\n.END\n";
        let (circuit, _, _) = SpiceParser::parse_bytes(netlist).unwrap();
        let x = circuit.get_global_param("x").expect("param x missing");
        assert!((x - 2.5).abs() < 1e-12, "x should be 2.5, got {x}");
    }

    /// Expression that references another param.
    #[test]
    fn test_param_reference_to_other_param() {
        let netlist = b"test\n.PARAM Vdd=5.0\n.PARAM Vhalf={Vdd/2}\n.END\n";
        let (circuit, _, _) = SpiceParser::parse_bytes(netlist).unwrap();
        let vhalf = circuit.get_global_param("vhalf").expect("Vhalf missing");
        assert!((vhalf - 2.5).abs() < 1e-12, "Vhalf should be 2.5, got {vhalf}");
    }

    /// Chained references: C depends on B which depends on A.
    #[test]
    fn test_param_chain_references() {
        let netlist = b"test\n.PARAM A=3.0\n.PARAM B={A*2}\n.PARAM C={B+1}\n.END\n";
        let (circuit, _, _) = SpiceParser::parse_bytes(netlist).unwrap();
        let c = circuit.get_global_param("c").expect("C missing");
        assert!((c - 7.0).abs() < 1e-12, "C should be 7.0, got {c}");
    }

    /// Multiple arithmetic ops in a single expression.
    #[test]
    fn test_param_complex_arithmetic() {
        let netlist = b"test\n.PARAM Gain={3*2+1}\n.END\n";
        let (circuit, _, _) = SpiceParser::parse_bytes(netlist).unwrap();
        let g = circuit.get_global_param("gain").expect("Gain missing");
        assert!((g - 7.0).abs() < 1e-12, "Gain should be 7.0, got {g}");
    }

    /// sqrt() function inside a .PARAM expression.
    #[test]
    fn test_param_sqrt_function() {
        let netlist = b"test\n.PARAM s={sqrt(9.0)}\n.END\n";
        let (circuit, _, _) = SpiceParser::parse_bytes(netlist).unwrap();
        let s = circuit.get_global_param("s").expect("s missing");
        assert!((s - 3.0).abs() < 1e-12, "s should be 3.0, got {s}");
    }

    /// Forward reference: Vhalf appears before Vdd in the file.
    #[test]
    fn test_param_forward_reference() {
        let netlist = b"test\n.PARAM Vhalf={Vdd/2}\n.PARAM Vdd=5.0\n.END\n";
        let (circuit, _, _) = SpiceParser::parse_bytes(netlist).unwrap();
        let vhalf = circuit.get_global_param("vhalf").expect("Vhalf missing");
        assert!((vhalf - 2.5).abs() < 1e-12, "Vhalf should be 2.5, got {vhalf}");
    }

    /// Circular dependency returns an error.
    #[test]
    fn test_param_circular_reference_error() {
        let netlist = b"test\n.PARAM A={B+1}\n.PARAM B={A+1}\n.END\n";
        let result = SpiceParser::parse_bytes(netlist);
        assert!(
            result.is_err(),
            "circular .PARAM dependency should produce a parse error"
        );
    }

    /// SI suffix in expression (k = 1000).
    #[test]
    fn test_param_si_suffix_in_expression() {
        let netlist = b"test\n.PARAM R={1k}\n.END\n";
        let (circuit, _, _) = SpiceParser::parse_bytes(netlist).unwrap();
        let r = circuit.get_global_param("r").expect("R missing");
        assert!((r - 1000.0).abs() < 1e-9, "R should be 1000 (1k), got {r}");
    }

    /// Deferred device parameter with {expr} syntax: braces are stripped and
    /// the expression resolves to the correct numeric value.
    #[test]
    fn test_param_device_brace_expr_resolved() {
        let netlist = b"test\n\
            .PARAM Rbase=1k\n\
            R1 a 0 {Rbase*2}\n\
            .OP\n\
            .END\n";
        let (circuit, _, _) = SpiceParser::parse_bytes(netlist).unwrap();
        let r1 = circuit.find_device("r1").expect("R1 not found");
        let val = r1.params.get("resistance").unwrap_or(0.0);
        assert!(
            (val - 2000.0).abs() < 1e-9,
            "R1 resistance should be 2000 (Rbase*2), got {val}"
        );
    }

    /// Deferred evaluation with topological sort: forward-referenced param
    /// used in a device value resolves correctly.
    #[test]
    fn test_param_forward_ref_device_value() {
        let netlist = b"test\n\
            R1 a 0 {Rval}\n\
            .PARAM Rval={Base+500}\n\
            .PARAM Base=1k\n\
            .OP\n\
            .END\n";
        let (circuit, _, _) = SpiceParser::parse_bytes(netlist).unwrap();
        let rval = circuit.get_global_param("rval").expect("Rval not found");
        assert!(
            (rval - 1500.0).abs() < 1e-9,
            "Rval should be 1500, got {rval}"
        );
        let r1 = circuit.find_device("r1").expect("R1 not found");
        let val = r1.params.get("resistance").unwrap_or(0.0);
        assert!(
            (val - 1500.0).abs() < 1e-9,
            "R1 resistance should be 1500, got {val}"
        );
    }

    /// Multiple devices with {expr} values from the same .PARAM.
    #[test]
    fn test_param_multiple_devices_same_param() {
        let netlist = b"test\n\
            .PARAM G=0.01\n\
            R1 a b {1/G}\n\
            R2 b 0 {2/G}\n\
            .OP\n\
            .END\n";
        let (circuit, _, _) = SpiceParser::parse_bytes(netlist).unwrap();
        let r1 = circuit.find_device("r1").expect("R1 not found");
        let r1v = r1.params.get("resistance").unwrap_or(0.0);
        assert!(
            (r1v - 100.0).abs() < 1e-9,
            "R1 should be 1/0.01=100, got {r1v}"
        );
        let r2 = circuit.find_device("r2").expect("R2 not found");
        let r2v = r2.params.get("resistance").unwrap_or(0.0);
        assert!(
            (r2v - 200.0).abs() < 1e-9,
            "R2 should be 2/0.01=200, got {r2v}"
        );
    }

    /// HSPICE-style single-quote expression in .PARAM.
    #[test]
    fn test_param_single_quote_expression() {
        let netlist = b"test\n.PARAM x='3*4+1'\n.END\n";
        let (circuit, _, _) = SpiceParser::parse_bytes(netlist).unwrap();
        let x = circuit.get_global_param("x").expect("x missing");
        assert!((x - 13.0).abs() < 1e-12, "x should be 13, got {x}");
    }
}

#[cfg(test)]
mod spiceparser_tests {
    use super::*;

    /// Helper: parse bytes using the public tuple API.
    fn parse_public(input: &str) -> (incspice_core::Circuit, Vec<AnalysisStatement>, SimOptions) {
        SpiceParser::parse_bytes(input.as_bytes()).expect("parse failed")
    }

    #[test]
    fn test_spice_parser_parse_bytes_rc() {
        // Simple RC circuit with a transient analysis.
        let netlist = "\
RC circuit\n\
Vs vin gnd 5.0\n\
R1 vin out 1k\n\
C1 out gnd 1u\n\
.TRAN 1n 10u\n\
.end\n";
        let (circuit, analyses, _opts) = parse_public(netlist);
        // Circuit should have 3 devices
        assert_eq!(circuit.devices().len(), 3);
        // Should have a TRAN analysis statement
        assert_eq!(analyses.len(), 1);
        assert_eq!(analyses[0].kind, AnalysisKind::Tran);
        let tstep = analyses[0].params.iter().find(|(k, _)| k == "tstep").map(|(_, v)| *v).unwrap();
        let tstop = analyses[0].params.iter().find(|(k, _)| k == "tstop").map(|(_, v)| *v).unwrap();
        assert!((tstep - 1e-9).abs() < 1e-18, "tstep should be 1e-9, got {tstep}");
        assert!((tstop - 10e-6).abs() < 1e-15, "tstop should be 10u, got {tstop}");
    }

    #[test]
    fn test_analysis_statement_dc_sweep_params() {
        let netlist = "\
DC sweep test\n\
V1 vin gnd 0\n\
R1 vin out 1k\n\
.DC V1 0 5 0.1\n\
.end\n";
        let (_circuit, analyses, _opts) = parse_public(netlist);
        assert_eq!(analyses.len(), 1);
        assert_eq!(analyses[0].kind, AnalysisKind::DcSweep);
        let params = &analyses[0].params;
        // Should have __dc_src__v1
        let has_src = params.iter().any(|(k, _)| k.starts_with("__dc_src__"));
        assert!(has_src, "expected __dc_src__ param, got: {params:?}");
        let start = params.iter().find(|(k, _)| k == "start").map(|(_, v)| *v).unwrap();
        let stop  = params.iter().find(|(k, _)| k == "stop").map(|(_, v)| *v).unwrap();
        let step  = params.iter().find(|(k, _)| k == "step").map(|(_, v)| *v).unwrap();
        assert!((start - 0.0).abs() < 1e-12, "start should be 0, got {start}");
        assert!((stop  - 5.0).abs() < 1e-12, "stop should be 5, got {stop}");
        assert!((step  - 0.1).abs() < 1e-12, "step should be 0.1, got {step}");
    }

    #[test]
    fn test_analysis_statement_tran_uic() {
        let netlist = "\
Tran UIC test\n\
V1 vin gnd 1\n\
R1 vin out 1k\n\
C1 out gnd 1u\n\
.TRAN 1n 100n 0 UIC\n\
.end\n";
        let (_circuit, analyses, _opts) = parse_public(netlist);
        assert_eq!(analyses.len(), 1);
        assert_eq!(analyses[0].kind, AnalysisKind::Tran);
        let uic = analyses[0].params.iter().find(|(k, _)| k == "uic").map(|(_, v)| *v).unwrap();
        assert!((uic - 1.0).abs() < 1e-12, "uic should be 1.0 when UIC keyword is present, got {uic}");
    }

    #[test]
    fn test_analysis_statement_ac_decade() {
        let netlist = "\
AC analysis test\n\
Vin vin gnd AC 1\n\
R1 vin out 1k\n\
C1 out gnd 100n\n\
.AC DEC 100 1 10MEG\n\
.end\n";
        let (_circuit, analyses, _opts) = parse_public(netlist);
        assert_eq!(analyses.len(), 1);
        assert_eq!(analyses[0].kind, AnalysisKind::Ac);
        let params = &analyses[0].params;
        let sweep_type = params.iter().find(|(k, _)| k == "sweep_type").map(|(_, v)| *v).unwrap();
        let npoints    = params.iter().find(|(k, _)| k == "npoints").map(|(_, v)| *v).unwrap();
        let fstart     = params.iter().find(|(k, _)| k == "fstart").map(|(_, v)| *v).unwrap();
        let fstop      = params.iter().find(|(k, _)| k == "fstop").map(|(_, v)| *v).unwrap();
        // DEC = 1.0
        assert!((sweep_type - 1.0).abs() < 1e-12, "DEC sweep_type should be 1.0, got {sweep_type}");
        assert!((npoints - 100.0).abs() < 1e-12, "npoints should be 100, got {npoints}");
        assert!((fstart - 1.0).abs() < 1e-12, "fstart should be 1.0, got {fstart}");
        assert!((fstop - 10e6).abs() < 1.0, "fstop should be 10e6, got {fstop}");
    }
}

#[cfg(test)]
mod flatten_tests {
    use super::*;

    /// Helper: run a full parse and return the circuit.
    fn parse_circuit(netlist: &[u8]) -> Circuit {
        SpiceParser::parse_netlist(netlist).unwrap().circuit
    }

    #[test]
    fn test_flatten_inverter_subckt_creates_two_mosfets() {
        let netlist = b"SPICE inverter test
.SUBCKT inv in out vdd vss
M1 out in vdd vdd PMOS W=1u L=0.1u
M2 out in vss vss NMOS W=0.5u L=0.1u
.ENDS inv
Vdd VDD 0 1.8
X1 net_a net_b VDD 0 inv
.END
";
        let circuit = parse_circuit(netlist);
        // After flattening: should have M_X1_M1, M_X1_M2, Vdd (3 devices total).
        // No X1 placeholder should remain.
        assert!(
            circuit.find_device("x1").is_none(),
            "X1 placeholder should be removed after flattening"
        );
        // Both MOSFETs should be present with prefixed names.
        let m1 = circuit.find_device("x1_m1");
        let m2 = circuit.find_device("x1_m2");
        assert!(m1.is_some(), "x1_m1 should exist after flattening");
        assert!(m2.is_some(), "x1_m2 should exist after flattening");
        // Verify kinds.
        assert_eq!(m1.unwrap().kind, incspice_core::DeviceKind::MosfetP, "M1 should be PMOS");
        assert_eq!(m2.unwrap().kind, incspice_core::DeviceKind::MosfetN, "M2 should be NMOS");
        // Count MOSFETs: exactly 2.
        let mosfet_count = circuit
            .devices()
            .iter()
            .filter(|d| {
                d.kind == incspice_core::DeviceKind::MosfetN
                    || d.kind == incspice_core::DeviceKind::MosfetP
            })
            .count();
        assert_eq!(mosfet_count, 2, "expected 2 MOSFETs after flattening, got {mosfet_count}");
    }

    #[test]
    fn test_flatten_node_naming() {
        // Verify that port nodes are mapped to instance-level nodes,
        // and internal nodes are prefixed with the instance name.
        let netlist = b"Node naming test
.SUBCKT inv in out vdd vss
M1 out in vdd vdd PMOS W=1u L=0.1u
M2 out in vss vss NMOS W=0.5u L=0.1u
.ENDS inv
Vdd VDD 0 1.8
X1 net_a net_b VDD 0 inv
.END
";
        let circuit = parse_circuit(netlist);
        let m2 = circuit.find_device("x1_m2").expect("x1_m2 should exist");
        // M2's gate (pin 1) should connect to net_a (the 'in' port of X1).
        let net_a_id = circuit.find_node("net_a").expect("net_a node");
        assert_eq!(
            m2.node(1),
            Some(net_a_id),
            "gate of x1_m2 should be net_a (mapped from 'in' port)"
        );
        // M2's source (pin 2) should connect to ground (the 'vss' port = 0).
        assert_eq!(
            m2.node(2),
            Some(incspice_core::NodeId::GROUND),
            "source of x1_m2 should be ground (vss=0)"
        );
    }

    #[test]
    fn test_flatten_multiple_instances() {
        // Two instances of the same subckt → 4 MOSFETs total.
        let netlist = b"Multiple instances test
.SUBCKT inv in out vdd vss
M1 out in vdd vdd PMOS W=1u L=0.1u
M2 out in vss vss NMOS W=0.5u L=0.1u
.ENDS inv
Vdd VDD 0 1.8
X1 a b VDD 0 inv
X2 c d VDD 0 inv
.END
";
        let circuit = parse_circuit(netlist);
        // No X-placeholders.
        assert!(circuit.find_device("x1").is_none(), "X1 placeholder should be gone");
        assert!(circuit.find_device("x2").is_none(), "X2 placeholder should be gone");
        // Both sets of MOSFETs present.
        assert!(circuit.find_device("x1_m1").is_some(), "x1_m1 missing");
        assert!(circuit.find_device("x1_m2").is_some(), "x1_m2 missing");
        assert!(circuit.find_device("x2_m1").is_some(), "x2_m1 missing");
        assert!(circuit.find_device("x2_m2").is_some(), "x2_m2 missing");
        let mosfet_count = circuit
            .devices()
            .iter()
            .filter(|d| {
                d.kind == incspice_core::DeviceKind::MosfetN
                    || d.kind == incspice_core::DeviceKind::MosfetP
            })
            .count();
        assert_eq!(mosfet_count, 4, "expected 4 MOSFETs (2 per instance), got {mosfet_count}");
    }

    #[test]
    fn test_flatten_no_x_instances_is_noop() {
        // A netlist with no X instances should parse unchanged.
        let netlist = b"No X instances
R1 vdd gnd 1k
C1 vdd gnd 1u
.END
";
        let circuit = parse_circuit(netlist);
        assert_eq!(circuit.devices().len(), 2, "should have exactly 2 devices");
    }

    #[test]
    fn test_flatten_unknown_subckt_removes_placeholder() {
        // An X instance referencing an undefined subckt: placeholder is removed,
        // parse succeeds (no error), other devices remain.
        let netlist = b"Unknown subckt test
R1 a b 1k
X1 c d e UNKNOWN_SUBCKT
.END
";
        // Should not return an error (just skips the unknown subckt).
        let result = SpiceParser::parse_netlist(netlist);
        assert!(result.is_ok(), "unknown subckt should not cause parse error");
        let circuit = result.unwrap().circuit;
        // X1 placeholder should be removed.
        assert!(circuit.find_device("x1").is_none(), "x1 placeholder should be removed");
        // R1 should still be present.
        assert!(circuit.find_device("r1").is_some(), "r1 should still exist");
    }

    #[test]
    fn test_flatten_param_overrides() {
        // Instance-level param overrides (e.g. W=2u) should be applied to
        // inlined devices.
        let netlist = b"Param overrides test
.SUBCKT inv in out vdd vss
M1 out in vdd vdd PMOS W=1u L=0.1u
.ENDS inv
Vdd VDD 0 1.8
X1 net_a net_b VDD 0 inv W=2u
.END
";
        let circuit = parse_circuit(netlist);
        let m1 = circuit.find_device("x1_m1").expect("x1_m1 should exist");
        // W should be overridden to 2u = 2e-6.
        let w = m1.params.get("w").expect("W param should exist");
        assert!(
            (w - 2e-6).abs() < 1e-15,
            "W should be overridden to 2u=2e-6, got {w}"
        );
    }

    /// After parsing a netlist with a voltage source carrying `AC 1`, the
    /// circuit must have exactly one `AcStimulus::VoltageSource` entry with
    /// the correct branch row and magnitude.
    #[test]
    fn test_register_ac_stimuli_voltage_source() {
        let netlist = "\
RC lowpass\n\
V1 in 0 AC 1\n\
R1 in out 1k\n\
C1 out 0 1n\n\
.AC DEC 10 1 1G\n\
.END\n";
        let netlist_parsed = SpiceParser::parse_netlist(netlist.as_bytes())
            .expect("parse should succeed");
        let circuit = &netlist_parsed.circuit;
        let stimuli = circuit.ac_stimuli();

        assert_eq!(
            stimuli.len(),
            1,
            "expected exactly one AC stimulus, got {}: {stimuli:?}",
            stimuli.len()
        );

        match stimuli[0] {
            incspice_core::AcStimulus::VoltageSource(branch_row, re, im) => {
                // num_vars = 2 (nodes `in` and `out`), V1 branch_index = 0 → branch_row = 2
                let expected_row = circuit.num_vars() as usize; // = num_vars + 0
                assert_eq!(
                    branch_row, expected_row,
                    "branch_row should be {expected_row}, got {branch_row}"
                );
                assert!(
                    (re - 1.0).abs() < 1e-12,
                    "real part should be 1.0 (AC mag=1, phase=0), got {re}"
                );
                assert!(
                    im.abs() < 1e-12,
                    "imag part should be 0.0, got {im}"
                );
            }
            other => panic!("expected VoltageSource stimulus, got {other:?}"),
        }
    }

    /// A current source with `AC 1` must produce a `CurrentSource` stimulus
    /// pointing at the correct KCL node rows.
    #[test]
    fn test_register_ac_stimuli_current_source() {
        // I1 from `out` to GND with AC=1, R1 parallel to GND.
        let netlist = "\
RC I-source test\n\
I1 out 0 AC 1\n\
R1 out 0 1k\n\
.AC DEC 5 1 1MEG\n\
.END\n";
        let netlist_parsed = SpiceParser::parse_netlist(netlist.as_bytes())
            .expect("parse should succeed");
        let circuit = &netlist_parsed.circuit;
        let stimuli = circuit.ac_stimuli();

        assert_eq!(
            stimuli.len(),
            1,
            "expected one AC stimulus, got {}: {stimuli:?}",
            stimuli.len()
        );

        match stimuli[0] {
            incspice_core::AcStimulus::CurrentSource(pos_row, neg_opt, re, im) => {
                // `out` is node 1 (after ground=0) → MNA index 0.
                assert_eq!(pos_row, 0, "pos_row for `out` should be 0, got {pos_row}");
                assert!(neg_opt.is_none(), "neg should be None (ground), got {neg_opt:?}");
                assert!((re - 1.0).abs() < 1e-12, "re should be 1.0, got {re}");
                assert!(im.abs() < 1e-12, "im should be 0.0, got {im}");
            }
            other => panic!("expected CurrentSource stimulus, got {other:?}"),
        }
    }

    #[test]
    fn test_func_square_in_param() {
        let netlist = "\
Test .FUNC example\n\
.FUNC square(x) {x*x}\n\
.PARAM y={square(3.0)}\n\
.END\n";
        let parsed = SpiceParser::parse_str(netlist).expect("parse should succeed");
        let y = parsed.circuit.global_params.get("y").copied().unwrap_or(0.0);
        assert!((y - 9.0).abs() < 1e-10, "square(3) should be 9, got {y}");
    }

    #[test]
    fn test_func_with_two_args() {
        let netlist = "\
Test multi-arg .FUNC\n\
.FUNC add(a, b) {a+b}\n\
.PARAM z={add(2.0, 3.0)}\n\
.END\n";
        let parsed = SpiceParser::parse_str(netlist).expect("parse should succeed");
        let z = parsed.circuit.global_params.get("z").copied().unwrap_or(0.0);
        assert!((z - 5.0).abs() < 1e-10, "add(2,3) should be 5, got {z}");
    }

    #[test]
    fn test_func_used_in_device_param() {
        // .func used in param that is then referenced by device
        let netlist = "\
Func device test\n\
.FUNC half(x) {x/2}\n\
.PARAM Vdd=5.0\n\
.PARAM Vhalf={half(Vdd)}\n\
V1 vdd 0 {Vhalf}\n\
.END\n";
        let parsed = SpiceParser::parse_str(netlist).expect("parse should succeed");
        let vhalf = parsed.circuit.global_params.get("vhalf").copied().unwrap_or(0.0);
        assert!((vhalf - 2.5).abs() < 1e-10, "half(5) should be 2.5, got {vhalf}");
    }

    #[test]
    fn test_noise_analysis_parsed() {
        let netlist = "\
Noise test\n\
V1 in 0 AC 1\n\
R1 in out 1k\n\
R2 out 0 1k\n\
.NOISE V(out) V1 DEC 10 1 1MEG\n\
.END\n";
        let parsed = SpiceParser::parse_str(netlist).expect("parse should succeed");
        assert_eq!(parsed.analyses.len(), 1, "should have 1 analysis");
        match &parsed.analyses[0] {
            crate::InternalAnalysisKind::Noise { output, source, fstart, fstop, npoints, .. } => {
                assert_eq!(output, "out");
                assert_eq!(source, "v1");
                assert!((fstart - 1.0).abs() < 1e-10, "fstart should be 1Hz");
                assert!((fstop - 1e6).abs() < 1e3, "fstop should be 1MHz");
                assert_eq!(*npoints, 10);
            }
            other => panic!("expected Noise analysis, got {:?}", other),
        }
    }
}

// ---------------------------------------------------------------------------
// Fix 9.2 / 9.3 validation tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod validation_tests {
    use super::*;

    fn parse(netlist: &str) -> Result<ParsedNetlist, ParseError> {
        SpiceParser::parse_str(netlist)
    }

    #[test]
    fn undefined_model_warns_but_parses_ok() {
        // A device referencing an undefined model should still parse
        // successfully (warning emitted to stderr, not an error).
        let netlist = "test\nD1 a k DMOD\n.END\n";
        let result = parse(netlist);
        assert!(result.is_ok(), "undefined model should warn, not error: {:?}", result.err());
    }

    #[test]
    fn subcircuit_pin_count_mismatch_errors() {
        // Subcircuit definition has 3 ports; instance supplies 2.
        let netlist = "test
.SUBCKT buf in out vdd
R1 in out 1k
R2 out vdd 1k
.ENDS buf
X1 a b buf
.END
";
        let result = parse(netlist);
        assert!(result.is_err(), "pin count mismatch should cause an error");
        let err = result.unwrap_err().to_string();
        assert!(err.contains("2 pins"), "error should mention actual count: {err}");
        assert!(err.contains("3 pins"), "error should mention expected count: {err}");
        assert!(err.contains("buf"), "error should mention subcircuit name: {err}");
    }

    #[test]
    fn subcircuit_pin_count_match_ok() {
        // Correct pin count should parse fine.
        let netlist = "test
.SUBCKT buf in out vdd
R1 in out 1k
R2 out vdd 1k
.ENDS buf
X1 a b vcc buf
.END
";
        let result = parse(netlist);
        assert!(result.is_ok(), "matching pin count should parse: {:?}", result.err());
    }
}

// ---------------------------------------------------------------------------
// Extended coverage tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod extended_tests {
    use super::*;

    fn parse(netlist: &str) -> Result<ParsedNetlist, ParseError> {
        SpiceParser::parse_str(netlist)
    }

    fn parse_circuit(netlist: &str) -> Circuit {
        parse(netlist).unwrap().circuit
    }

    // ── Resistor value variants ────────────────────────────────────────────

    #[test]
    fn test_resistor_mega_ohm() {
        let c = parse_circuit("test\nR1 a b 2.2meg\n.end\n");
        let r = c.find_device("r1").unwrap().params.get("resistance").unwrap();
        assert!((r - 2.2e6).abs() < 1.0, "2.2meg should be 2.2e6, got {r}");
    }

    #[test]
    fn test_resistor_scientific_notation() {
        let c = parse_circuit("test\nR1 a b 1.5e3\n.end\n");
        let r = c.find_device("r1").unwrap().params.get("resistance").unwrap();
        assert!((r - 1500.0).abs() < 0.01, "1.5e3 should be 1500, got {r}");
    }

    #[test]
    fn test_resistor_plain_integer() {
        let c = parse_circuit("test\nR1 a b 470\n.end\n");
        let r = c.find_device("r1").unwrap().params.get("resistance").unwrap();
        assert!((r - 470.0).abs() < 0.01, "470 ohm plain, got {r}");
    }

    #[test]
    fn test_resistor_milli_suffix() {
        // 500m = 0.5 ohm
        let c = parse_circuit("test\nR1 a b 500m\n.end\n");
        let r = c.find_device("r1").unwrap().params.get("resistance").unwrap();
        assert!((r - 0.5).abs() < 1e-12, "500m should be 0.5, got {r}");
    }

    // ── Capacitor value variants ───────────────────────────────────────────

    #[test]
    fn test_capacitor_pico() {
        let c = parse_circuit("test\nC1 a b 100p\n.end\n");
        let cap = c.find_device("c1").unwrap().params.get("capacitance").unwrap();
        assert!((cap - 100e-12).abs() < 1e-22, "100p = 1e-10, got {cap}");
    }

    #[test]
    fn test_capacitor_nano() {
        let c = parse_circuit("test\nC1 a b 10n\n.end\n");
        let cap = c.find_device("c1").unwrap().params.get("capacitance").unwrap();
        assert!((cap - 10e-9).abs() < 1e-20, "10n = 1e-8, got {cap}");
    }

    #[test]
    fn test_capacitor_scientific() {
        let c = parse_circuit("test\nC1 a b 4.7e-9\n.end\n");
        let cap = c.find_device("c1").unwrap().params.get("capacitance").unwrap();
        assert!((cap - 4.7e-9).abs() < 1e-20, "4.7e-9 F, got {cap}");
    }

    // ── Inductor ──────────────────────────────────────────────────────────

    #[test]
    fn test_inductor_micro() {
        let c = parse_circuit("test\nL1 a b 47u\n.end\n");
        let l = c.find_device("l1").unwrap().params.get("inductance").unwrap();
        assert!((l - 47e-6).abs() < 1e-17, "47u = 47e-6, got {l}");
    }

    #[test]
    fn test_inductor_milli() {
        let c = parse_circuit("test\nL1 a b 3.3m\n.end\n");
        let l = c.find_device("l1").unwrap().params.get("inductance").unwrap();
        assert!((l - 3.3e-3).abs() < 1e-14, "3.3m H, got {l}");
    }

    // ── Voltage source waveforms ───────────────────────────────────────────

    #[test]
    fn test_voltage_source_sin_waveform() {
        let c = parse_circuit("test\nVsin vin gnd SIN(0 1 1k)\n.end\n");
        let dev = c.find_device("vsin").unwrap();
        assert_eq!(dev.kind, DeviceKind::VoltageSource);
        let wk = dev.params.get("waveform_kind").unwrap();
        assert!((wk - 2.0).abs() < 1e-12, "SIN waveform_kind should be 2.0, got {wk}");
        let freq = dev.params.get("sin_freq").unwrap();
        assert!((freq - 1000.0).abs() < 0.01, "SIN freq should be 1k=1000, got {freq}");
    }

    #[test]
    fn test_voltage_source_pulse_params() {
        let c = parse_circuit("test\nV1 vp vn PULSE(0 5 0 1n 1n 5n 10n)\n.end\n");
        let dev = c.find_device("v1").unwrap();
        let v1 = dev.params.get("pulse_v1").unwrap();
        let v2 = dev.params.get("pulse_v2").unwrap();
        let pw = dev.params.get("pulse_pw").unwrap();
        let per = dev.params.get("pulse_per").unwrap();
        assert!((v1 - 0.0).abs() < 1e-12, "pulse_v1 should be 0, got {v1}");
        assert!((v2 - 5.0).abs() < 1e-12, "pulse_v2 should be 5, got {v2}");
        assert!((pw - 5e-9).abs() < 1e-21, "pulse_pw should be 5n, got {pw}");
        assert!((per - 10e-9).abs() < 1e-21, "pulse_per should be 10n, got {per}");
    }

    #[test]
    fn test_voltage_source_pwl_waveform() {
        let c = parse_circuit("test\nV1 a b PWL(0 0 1n 5 2n 0)\n.end\n");
        let dev = c.find_device("v1").unwrap();
        let wk = dev.params.get("waveform_kind").unwrap();
        assert!((wk - 3.0).abs() < 1e-12, "PWL waveform_kind should be 3.0, got {wk}");
        let cnt = dev.params.get("pwl_count").unwrap();
        assert!((cnt - 3.0).abs() < 1e-12, "pwl_count should be 3, got {cnt}");
    }

    #[test]
    fn test_voltage_source_dc_and_ac() {
        let c = parse_circuit("test\nV1 vin gnd DC 2.0 AC 1\n.end\n");
        let dev = c.find_device("v1").unwrap();
        let dc = dev.params.get("dc").unwrap();
        let ac = dev.params.get("ac_mag").unwrap();
        assert!((dc - 2.0).abs() < 1e-12, "dc should be 2.0, got {dc}");
        assert!((ac - 1.0).abs() < 1e-12, "ac_mag should be 1.0, got {ac}");
    }

    #[test]
    fn test_voltage_source_ac_only() {
        let c = parse_circuit("test\nV1 vin gnd AC 1\n.end\n");
        let dev = c.find_device("v1").unwrap();
        let ac = dev.params.get("ac_mag").unwrap();
        assert!((ac - 1.0).abs() < 1e-12, "ac_mag should be 1.0, got {ac}");
    }

    // ── Current source ─────────────────────────────────────────────────────

    #[test]
    fn test_current_source_micro() {
        let c = parse_circuit("test\nI1 net 0 100u\n.end\n");
        let dc = c.find_device("i1").unwrap().params.get("dc").unwrap();
        assert!((dc - 100e-6).abs() < 1e-18, "100u A, got {dc}");
    }

    #[test]
    fn test_current_source_ac() {
        let c = parse_circuit("test\nI1 out 0 AC 1\n.end\n");
        let dev = c.find_device("i1").unwrap();
        assert_eq!(dev.kind, DeviceKind::CurrentSource);
        let ac = dev.params.get("ac_mag").unwrap();
        assert!((ac - 1.0).abs() < 1e-12, "ac_mag should be 1.0, got {ac}");
    }

    // ── Diode with model ──────────────────────────────────────────────────

    #[test]
    fn test_diode_with_model_params() {
        let netlist = "test\n.MODEL MYDIODE D IS=1e-14 N=1.0\nD1 anode cathode MYDIODE\n.end\n";
        let c = parse_circuit(netlist);
        let dev = c.find_device("d1").unwrap();
        assert_eq!(dev.kind, DeviceKind::Diode);
        let is = dev.params.get("is").unwrap();
        assert!((is - 1e-14).abs() < 1e-25, "IS should be 1e-14, got {is}");
    }

    #[test]
    fn test_diode_terminals() {
        let c = parse_circuit("test\nD1 anode cathode dmod\n.end\n");
        let dev = c.find_device("d1").unwrap();
        let anode = c.find_node("anode").unwrap();
        let cath = c.find_node("cathode").unwrap();
        assert_eq!(dev.node(0), Some(anode));
        assert_eq!(dev.node(1), Some(cath));
    }

    // ── BJT ───────────────────────────────────────────────────────────────

    #[test]
    fn test_bjt_pnp_model() {
        let netlist = "test\n.MODEL PNP1 PNP\nQ1 c b e PNP1\n.end\n";
        let c = parse_circuit(netlist);
        let dev = c.find_device("q1").unwrap();
        assert_eq!(dev.kind, DeviceKind::BjtPnp);
    }

    #[test]
    fn test_bjt_four_terminals() {
        // Q with substrate node
        let c = parse_circuit("test\nQ1 c b e sub NPN\n.end\n");
        let dev = c.find_device("q1").unwrap();
        assert_eq!(dev.terminal_count(), 4, "BJT with substrate should have 4 terminals");
    }

    #[test]
    fn test_bjt_three_terminals() {
        let c = parse_circuit("test\nQ1 c b e NPN\n.end\n");
        let dev = c.find_device("q1").unwrap();
        assert_eq!(dev.terminal_count(), 3, "BJT without substrate should have 3 terminals");
    }

    // ── MOSFET ────────────────────────────────────────────────────────────

    #[test]
    fn test_mosfet_pmos_kind() {
        let netlist = "test\n.MODEL PMOD PMOS\nM1 d g s b PMOD W=2u L=0.18u\n.end\n";
        let c = parse_circuit(netlist);
        let dev = c.find_device("m1").unwrap();
        assert_eq!(dev.kind, DeviceKind::MosfetP);
    }

    #[test]
    fn test_mosfet_additional_params() {
        let netlist = "test\nM1 d g s b NMOS W=10u L=1u AD=20p AS=20p\n.end\n";
        let c = parse_circuit(netlist);
        let dev = c.find_device("m1").unwrap();
        let ad = dev.params.get("ad").unwrap();
        let as_ = dev.params.get("as").unwrap();
        assert!((ad - 20e-12).abs() < 1e-22, "AD should be 20p, got {ad}");
        assert!((as_ - 20e-12).abs() < 1e-22, "AS should be 20p, got {as_}");
    }

    // ── SUBCKT ────────────────────────────────────────────────────────────

    #[test]
    fn test_subckt_two_port() {
        let netlist = "test\n.SUBCKT buf in out\n.ENDS buf\n.end\n";
        let c = parse_circuit(netlist);
        let def = c.find_subckt_def("buf").unwrap();
        assert_eq!(def.terminals.len(), 2);
        assert_eq!(def.terminals[0], "in");
        assert_eq!(def.terminals[1], "out");
    }

    #[test]
    fn test_subckt_ends_with_name() {
        // .ENDS with subckt name — must parse fine
        let netlist = "test\n.SUBCKT mymod a b\nR1 a b 1k\n.ENDS mymod\n.end\n";
        let result = parse(netlist);
        assert!(result.is_ok(), "ENDS with name should parse OK");
        let c = result.unwrap().circuit;
        assert!(c.find_subckt_def("mymod").is_some());
    }

    #[test]
    fn test_subckt_instantiation_creates_nodes() {
        let netlist = "test\n.SUBCKT res a b\nR1 a b 1k\n.ENDS res\nX1 net1 net2 res\n.end\n";
        let c = parse_circuit(netlist);
        assert!(c.find_node("net1").is_some(), "net1 should exist after X instantiation");
        assert!(c.find_node("net2").is_some(), "net2 should exist after X instantiation");
    }

    // ── .IC initial conditions ─────────────────────────────────────────────

    #[test]
    fn test_ic_directive() {
        let netlist = "test\n.IC V(out)=3.3\n.end\n";
        let c = parse_circuit(netlist);
        let out_id = c.find_node("out").expect("out node from .IC");
        let ic_val = c.initial_conditions().iter()
            .find(|vc| vc.pos_node == out_id)
            .map(|vc| vc.voltage);
        assert!(ic_val.is_some(), ".IC value should be registered");
        let v = ic_val.unwrap();
        assert!((v - 3.3).abs() < 1e-12, "IC should be 3.3V, got {v}");
    }

    #[test]
    fn test_ic_multiple_nodes() {
        let netlist = "test\n.IC V(a)=1.0 V(b)=2.0\n.end\n";
        let c = parse_circuit(netlist);
        assert!(c.find_node("a").is_some(), "node a from .IC");
        assert!(c.find_node("b").is_some(), "node b from .IC");
    }

    // ── .NODESET ──────────────────────────────────────────────────────────

    #[test]
    fn test_nodeset_directive() {
        let netlist = "test\n.NODESET V(vout)=2.5\n.end\n";
        let c = parse_circuit(netlist);
        let vout_id = c.find_node("vout").expect("vout from .NODESET");
        let ns_val = c.node_sets().iter()
            .find(|vc| vc.pos_node == vout_id)
            .map(|vc| vc.voltage);
        assert!(ns_val.is_some(), ".NODESET value should be registered");
        let v = ns_val.unwrap();
        assert!((v - 2.5).abs() < 1e-12, "NODESET should be 2.5V, got {v}");
    }

    // ── .PARAM expressions ────────────────────────────────────────────────

    #[test]
    fn test_param_multiple_on_one_line() {
        let netlist = "test\n.PARAM A=1k B=2k\n.end\n";
        let c = parse_circuit(netlist);
        let a = c.get_global_param("a").unwrap();
        let b = c.get_global_param("b").unwrap();
        assert!((a - 1000.0).abs() < 0.01);
        assert!((b - 2000.0).abs() < 0.01);
    }

    #[test]
    fn test_param_expression_mul() {
        let netlist = "test\n.PARAM R={2*1k}\n.end\n";
        let c = parse_circuit(netlist);
        let r = c.get_global_param("r").unwrap();
        assert!((r - 2000.0).abs() < 0.01, "2*1k should be 2000, got {r}");
    }

    // ── .FUNC ────────────────────────────────────────────────────────────

    #[test]
    fn test_func_single_arg() {
        let netlist = "test\n.FUNC inv(x) {1.0/x}\n.PARAM y={inv(2.0)}\n.end\n";
        let c = parse_circuit(netlist);
        let y = c.get_global_param("y").unwrap();
        assert!((y - 0.5).abs() < 1e-12, "inv(2) should be 0.5, got {y}");
    }

    #[test]
    fn test_func_no_args() {
        // .FUNC with constant body
        let netlist = "test\n.FUNC pi_approx() {3.14159}\n.PARAM p={pi_approx()}\n.end\n";
        let result = parse(netlist);
        // It should at least not crash
        assert!(result.is_ok(), "zero-arg func should not panic");
    }

    // ── .MODEL definitions ────────────────────────────────────────────────

    #[test]
    fn test_model_pmos_stored() {
        let netlist = "test\n.MODEL PMOD PMOS TOX=5e-9 VTH0=-0.7\n.end\n";
        let c = parse_circuit(netlist);
        let m = c.find_model("pmod").unwrap();
        assert_eq!(m.0, incspice_core::ModelKind::Pmos);
        let tox = m.1.get("tox").unwrap();
        assert!((tox - 5e-9).abs() < 1e-19, "TOX should be 5e-9, got {tox}");
    }

    #[test]
    fn test_model_npn_stored() {
        let netlist = "test\n.MODEL NPN1 NPN IS=1e-15 BF=100\n.end\n";
        let c = parse_circuit(netlist);
        let m = c.find_model("npn1").unwrap();
        assert_eq!(m.0, incspice_core::ModelKind::Npn);
        let bf = m.1.get("bf").unwrap();
        assert!((bf - 100.0).abs() < 1e-9, "BF should be 100, got {bf}");
    }

    #[test]
    fn test_model_diode_stored() {
        let netlist = "test\n.MODEL D1 D IS=1e-12 N=1.5\n.end\n";
        let c = parse_circuit(netlist);
        let m = c.find_model("d1").unwrap();
        assert_eq!(m.0, incspice_core::ModelKind::Diode);
        let n = m.1.get("n").unwrap();
        assert!((n - 1.5).abs() < 1e-12, "N should be 1.5, got {n}");
    }

    #[test]
    fn test_model_pnp_stored() {
        let netlist = "test\n.MODEL PNP1 PNP IS=2e-16 BF=50\n.end\n";
        let c = parse_circuit(netlist);
        let m = c.find_model("pnp1").unwrap();
        assert_eq!(m.0, incspice_core::ModelKind::Pnp);
    }

    // ── .TRAN variants ────────────────────────────────────────────────────

    #[test]
    fn test_tran_with_tstart() {
        let netlist = "test\n.TRAN 1n 100n 10n\n.end\n";
        let result = parse(netlist).unwrap();
        match &result.analyses[0] {
            InternalAnalysisKind::Transient { tstep, tstop, tstart, .. } => {
                assert!((tstep - 1e-9).abs() < 1e-18);
                assert!((tstop - 100e-9).abs() < 1e-16);
                assert!((tstart - 10e-9).abs() < 1e-18, "tstart should be 10n, got {tstart}");
            }
            other => panic!("expected Transient, got {other:?}"),
        }
    }

    #[test]
    fn test_tran_uic_flag() {
        let netlist = "test\n.TRAN 1n 10n UIC\n.end\n";
        let result = parse(netlist).unwrap();
        match &result.analyses[0] {
            InternalAnalysisKind::Transient { uic, .. } => {
                assert!(*uic, "UIC flag should be true");
            }
            other => panic!("expected Transient, got {other:?}"),
        }
    }

    // ── .AC variants ──────────────────────────────────────────────────────

    #[test]
    fn test_ac_lin_sweep() {
        let netlist = "test\n.AC LIN 100 10 1MEG\n.end\n";
        let result = parse(netlist).unwrap();
        match &result.analyses[0] {
            InternalAnalysisKind::Ac { sweep, fstart, fstop } => {
                match sweep {
                    AcSweepType::Lin(n) => assert_eq!(*n, 100),
                    other => panic!("expected Lin sweep, got {other:?}"),
                }
                assert!((fstart - 10.0).abs() < 0.01, "fstart=10, got {fstart}");
                assert!((fstop - 1e6).abs() < 1.0, "fstop=1MEG, got {fstop}");
            }
            other => panic!("expected Ac, got {other:?}"),
        }
    }

    #[test]
    fn test_ac_oct_sweep() {
        let netlist = "test\n.AC OCT 5 100 100k\n.end\n";
        let result = parse(netlist).unwrap();
        match &result.analyses[0] {
            InternalAnalysisKind::Ac { sweep, .. } => {
                match sweep {
                    AcSweepType::Oct(n) => assert_eq!(*n, 5),
                    other => panic!("expected Oct sweep, got {other:?}"),
                }
            }
            other => panic!("expected Ac, got {other:?}"),
        }
    }

    // ── .DC ───────────────────────────────────────────────────────────────

    #[test]
    fn test_dc_sweep_parsed() {
        let netlist = "test\nV1 vin gnd 0\n.DC V1 -5 5 0.1\n.end\n";
        let result = parse(netlist).unwrap();
        match &result.analyses[0] {
            InternalAnalysisKind::DcSweep { source, start, stop, step, .. } => {
                assert_eq!(source, "v1");
                assert!((start - (-5.0)).abs() < 1e-12);
                assert!((stop - 5.0).abs() < 1e-12);
                assert!((step - 0.1).abs() < 1e-12);
            }
            other => panic!("expected DcSweep, got {other:?}"),
        }
    }

    #[test]
    fn test_op_analysis() {
        let netlist = "test\n.OP\n.end\n";
        let result = parse(netlist).unwrap();
        assert_eq!(result.analyses.len(), 1);
        assert!(matches!(result.analyses[0], InternalAnalysisKind::DcOp));
    }

    // ── .NOISE variants ───────────────────────────────────────────────────

    #[test]
    fn test_noise_lin_sweep() {
        let netlist = "\
Noise lin test\n\
V1 in 0 AC 1\n\
R1 in out 1k\n\
R2 out 0 1k\n\
.NOISE V(out) V1 LIN 50 1 1000\n\
.END\n";
        let result = SpiceParser::parse_str(netlist).unwrap();
        assert!(!result.analyses.is_empty(), "should have at least one analysis");
        match &result.analyses[0] {
            InternalAnalysisKind::Noise { sweep, fstart, fstop, .. } => {
                match sweep {
                    AcSweepType::Lin(n) => assert_eq!(*n, 50, "npoints should be 50"),
                    other => panic!("expected Lin sweep, got {other:?}"),
                }
                assert!((fstart - 1.0).abs() < 1e-10, "fstart should be 1 Hz");
                assert!((fstop - 1000.0).abs() < 0.1, "fstop should be 1000 Hz");
            }
            other => panic!("expected Noise, got {other:?}"),
        }
    }

    #[test]
    fn test_noise_output_and_source() {
        let netlist = "test\nV1 in 0 1\nR1 in out 1k\n.NOISE V(out) V1 DEC 20 1 10MEG\n.end\n";
        let result = parse(netlist).unwrap();
        match &result.analyses[0] {
            InternalAnalysisKind::Noise { output, source, npoints, .. } => {
                assert_eq!(output, "out");
                assert_eq!(source, "v1");
                assert_eq!(*npoints, 20);
            }
            other => panic!("expected Noise, got {other:?}"),
        }
    }

    // ── Comments ──────────────────────────────────────────────────────────

    #[test]
    fn test_star_comment_at_line_start() {
        // Lines starting with '*' should be skipped; only R1 should be added.
        let netlist = "test\n* This is a full-line comment\nR1 a b 1k\n.end\n";
        let c = parse_circuit(netlist);
        assert_eq!(c.devices().len(), 1, "only R1 should be added");
    }

    #[test]
    fn test_dollar_inline_comment() {
        let netlist = "test\nR1 a b 1k $ inline comment here\n.end\n";
        let c = parse_circuit(netlist);
        let r = c.find_device("r1").unwrap().params.get("resistance").unwrap();
        assert!((r - 1000.0).abs() < 0.01, "resistance should still be 1k despite comment");
    }

    #[test]
    fn test_semicolon_inline_comment() {
        let netlist = "test\nC1 a b 10n ; load capacitor\n.end\n";
        let c = parse_circuit(netlist);
        let cap = c.find_device("c1").unwrap().params.get("capacitance").unwrap();
        assert!((cap - 10e-9).abs() < 1e-20, "capacitance should be 10n");
    }

    // ── Line continuation ─────────────────────────────────────────────────

    #[test]
    fn test_line_continuation_resistor() {
        // Value on continuation line
        let netlist = "test\nR1 a b\n+ 1k\n.end\n";
        let c = parse_circuit(netlist);
        let r = c.find_device("r1").unwrap().params.get("resistance").unwrap();
        assert!((r - 1000.0).abs() < 0.01, "resistance on continuation line should be 1k");
    }

    #[test]
    fn test_line_continuation_param() {
        let netlist = "test\n.PARAM A=1k\n+ B=2k\n.end\n";
        let c = parse_circuit(netlist);
        // A should parse fine; continuation extends the .PARAM line
        let a = c.get_global_param("a");
        assert!(a.is_some(), ".PARAM with continuation should parse A");
    }

    // ── Case insensitivity ────────────────────────────────────────────────

    #[test]
    fn test_case_insensitive_nmos() {
        let netlist = "test\nM1 d g s b nmos W=1u L=0.1u\n.end\n";
        let c = parse_circuit(netlist);
        let dev = c.find_device("m1").unwrap();
        assert_eq!(dev.kind, DeviceKind::MosfetN, "lowercase 'nmos' should set MosfetN");
    }

    #[test]
    fn test_case_insensitive_pmos() {
        let netlist = "test\nM1 d g s b PMOS W=2u L=0.5u\n.end\n";
        let c = parse_circuit(netlist);
        let dev = c.find_device("m1").unwrap();
        assert_eq!(dev.kind, DeviceKind::MosfetP, "uppercase PMOS should set MosfetP");
    }

    #[test]
    fn test_case_insensitive_directives() {
        let netlist = "test\n.tran 1n 100n\n.End\n";
        let result = parse(netlist);
        assert!(result.is_ok(), "lowercase .tran and mixed-case .End should parse OK");
        let result = result.unwrap();
        assert_eq!(result.analyses.len(), 1);
    }

    // ── Expressions in braces ─────────────────────────────────────────────

    #[test]
    fn test_expression_in_resistor_value() {
        let netlist = "test\n.PARAM R0=500\nR1 a b {2*R0}\n.end\n";
        let c = parse_circuit(netlist);
        let r = c.find_device("r1").unwrap().params.get("resistance").unwrap();
        assert!((r - 1000.0).abs() < 1.0, "expression {{2*R0}} should evaluate to 1000, got {r}");
    }

    #[test]
    fn test_expression_in_source_value() {
        let netlist = "test\n.PARAM Vdd=3.3\nV1 vin 0 {Vdd}\n.end\n";
        let c = parse_circuit(netlist);
        let dc = c.find_device("v1").unwrap().params.get("dc").unwrap();
        assert!((dc - 3.3).abs() < 1e-12, "dc from expression should be 3.3V, got {dc}");
    }

    // ── VCCS (G-device) ───────────────────────────────────────────────────

    #[test]
    fn test_vccs_parsed() {
        let netlist = "test\nG1 out gnd in gnd 0.01\n.end\n";
        let c = parse_circuit(netlist);
        let dev = c.find_device("g1").unwrap();
        assert_eq!(dev.kind, DeviceKind::Vccs);
        assert_eq!(dev.terminal_count(), 4);
        let gain = dev.params.get("gain").unwrap();
        assert!((gain - 0.01).abs() < 1e-12, "gain should be 0.01, got {gain}");
    }

    // ── CCCS (F-device) ───────────────────────────────────────────────────

    #[test]
    fn test_cccs_parsed() {
        let netlist = "test\nF1 out gnd Vsense 5.0\n.end\n";
        let c = parse_circuit(netlist);
        let dev = c.find_device("f1").unwrap();
        assert_eq!(dev.kind, DeviceKind::Cccs);
        let gain = dev.params.get("gain").unwrap();
        assert!((gain - 5.0).abs() < 1e-12, "CCCS gain should be 5.0, got {gain}");
    }

    // ── CCVS (H-device) ───────────────────────────────────────────────────

    #[test]
    fn test_ccvs_parsed() {
        let netlist = "test\nH1 out gnd Vsense 1k\n.end\n";
        let c = parse_circuit(netlist);
        let dev = c.find_device("h1").unwrap();
        assert_eq!(dev.kind, DeviceKind::Ccvs);
        let trans = dev.params.get("transresistance").unwrap();
        assert!((trans - 1000.0).abs() < 0.01, "transresistance should be 1k, got {trans}");
    }

    // ── Device count ──────────────────────────────────────────────────────

    #[test]
    fn test_empty_netlist_no_devices() {
        // Only title + .END, no devices
        let c = parse_circuit("empty test\n.end\n");
        assert_eq!(c.devices().len(), 0, "empty netlist should have 0 devices");
    }

    #[test]
    fn test_single_device_device_count() {
        let c = parse_circuit("test\nR1 a b 1k\n.end\n");
        assert_eq!(c.devices().len(), 1);
    }

    // ── .OPTIONS ─────────────────────────────────────────────────────────

    #[test]
    fn test_options_gmin() {
        let netlist = "test\n.OPTIONS GMIN=1e-15\n.end\n";
        let result = parse(netlist).unwrap();
        let gmin = result.options.gmin.unwrap();
        assert!((gmin - 1e-15).abs() < 1e-25, "gmin should be 1e-15, got {gmin}");
    }

    #[test]
    fn test_options_vntol() {
        let netlist = "test\n.OPTIONS VNTOL=1e-7\n.end\n";
        let result = parse(netlist).unwrap();
        let vntol = result.options.vntol.unwrap();
        assert!((vntol - 1e-7).abs() < 1e-17, "vntol should be 1e-7, got {vntol}");
    }

    // ── .GLOBAL ───────────────────────────────────────────────────────────

    #[test]
    fn test_global_single_node() {
        let netlist = "test\n.GLOBAL VDD\n.end\n";
        let c = parse_circuit(netlist);
        assert!(c.globals().contains(&"vdd".to_string()));
    }

    // ── SimOptions via parse_bytes ─────────────────────────────────────────

    #[test]
    fn test_parse_bytes_returns_default_sim_options() {
        let netlist = b"test\nR1 a b 1k\n.end\n";
        let (_c, _analyses, opts) = SpiceParser::parse_bytes(netlist).unwrap();
        assert!((opts.temp - 27.0).abs() < 0.01, "default temp should be 27.0, got {}", opts.temp);
        assert!((opts.gmin - 1e-12).abs() < 1e-22, "default gmin should be 1e-12");
        assert!((opts.ptranmax - 0.0).abs() < 1e-30, "default ptranmax should be 0.0");
    }

    #[test]
    fn test_parse_bytes_ptranmax_option() {
        let netlist = b"test\n.OPTIONS ptranmax=1u\nR1 a b 1k\n.end\n";
        let (_c, _analyses, opts) = SpiceParser::parse_bytes(netlist).unwrap();
        assert!((opts.ptranmax - 1e-6).abs() < 1e-16, "ptranmax should be 1e-6, got {}", opts.ptranmax);
    }

    #[test]
    fn test_parse_bytes_pseudotransient_option() {
        let netlist = b"test\n.OPTIONS PSEUDOTRANSIENT=1\nR1 a b 1k\n.end\n";
        let (_c, _analyses, opts) = SpiceParser::parse_bytes(netlist).unwrap();
        assert!(opts.ptranmax > 0.0, "PSEUDOTRANSIENT=1 should enable ptranmax, got {}", opts.ptranmax);
    }

    // ── Multiple analyses ──────────────────────────────────────────────────

    #[test]
    fn test_multiple_analysis_statements() {
        let netlist = "test\n.OP\n.TRAN 1n 100n\n.AC DEC 10 1 1G\n.end\n";
        let result = parse(netlist).unwrap();
        assert_eq!(result.analyses.len(), 3, "should have 3 analysis statements");
    }

    // ── Node mapping ──────────────────────────────────────────────────────

    #[test]
    fn test_numeric_node_names() {
        // SPICE uses numeric node names (0=GND, 1, 2, ...)
        let netlist = "test\nR1 1 0 1k\n.end\n";
        let c = parse_circuit(netlist);
        let dev = c.find_device("r1").unwrap();
        assert_eq!(dev.terminal_count(), 2);
        assert_eq!(dev.node(1), Some(NodeId::GROUND), "node 0 should map to GROUND");
    }

    // ── Behavioral source (B-device) ──────────────────────────────────────

    #[test]
    fn test_bsource_voltage() {
        let netlist = "test\nB1 out gnd V=5.0\n.end\n";
        let c = parse_circuit(netlist);
        let dev = c.find_device("b1").unwrap();
        // Kind is BsourceV per ELEMENT_PREFIX map
        assert_eq!(dev.kind, DeviceKind::BsourceV);
    }

    // ── parse_bytes returns analysis kind ─────────────────────────────────

    #[test]
    fn test_parse_bytes_tran_analysis_kind() {
        let netlist = b"test\n.TRAN 1n 10u\n.end\n";
        let (_c, analyses, _opts) = SpiceParser::parse_bytes(netlist).unwrap();
        assert_eq!(analyses.len(), 1);
        assert_eq!(analyses[0].kind, AnalysisKind::Tran);
    }

    #[test]
    fn test_parse_bytes_ac_analysis_kind() {
        let netlist = b"test\n.AC DEC 10 1 1MEG\n.end\n";
        let (_c, analyses, _opts) = SpiceParser::parse_bytes(netlist).unwrap();
        assert_eq!(analyses.len(), 1);
        assert_eq!(analyses[0].kind, AnalysisKind::Ac);
    }

    #[test]
    fn test_parse_bytes_dc_op_kind() {
        let netlist = b"test\n.OP\n.end\n";
        let (_c, analyses, _opts) = SpiceParser::parse_bytes(netlist).unwrap();
        assert_eq!(analyses.len(), 1);
        assert_eq!(analyses[0].kind, AnalysisKind::DcOp);
    }

    #[test]
    fn test_parse_bytes_dc_leading_decimal_step() {
        let netlist = b"test\n.DC VDD 0 1 .1\n.end\n";
        let (_c, analyses, _opts) = SpiceParser::parse_bytes(netlist).unwrap();
        assert_eq!(analyses.len(), 1);
        assert_eq!(analyses[0].kind, AnalysisKind::DcSweep);
        assert_eq!(analyses[0].params[3].0, "step");
        assert!((analyses[0].params[3].1 - 0.1).abs() < 1e-12);
    }

    // ── XSPICE A-element parsing ──────────────────────────────────────

    #[test]
    fn test_parse_xspice_a_element_paren_ports() {
        // Scalar analog ports using () syntax (as in test fixtures)
        let c = parse_circuit(
            "test\nAinv (in) (vdigital) INVMOD\n\
             .model INVMOD d_inverter (rise_delay=0.1n fall_delay=0.1n)\n\
             .end\n",
        );
        // The A-device should be parsed with DeviceKind::Xspice
        let dev = c.devices().iter().find(|d| d.name.starts_with("a")).unwrap();
        assert_eq!(dev.kind, DeviceKind::Xspice);
        // Two port nodes: in, vdigital
        assert_eq!(dev.terminal_count(), 2);
    }

    #[test]
    fn test_parse_xspice_a_element_bracket_ports() {
        // Vector digital ports using [] syntax
        let c = parse_circuit(
            "test\nabridge1 [in1 in2] [out] adc_bridge_model\n\
             .model adc_bridge_model adc_bridge (in_low=0.5 in_high=1.5)\n\
             .end\n",
        );
        let dev = c.devices().iter().find(|d| d.name.starts_with("a")).unwrap();
        assert_eq!(dev.kind, DeviceKind::Xspice);
        // Three port nodes: in1, in2, out
        assert_eq!(dev.terminal_count(), 3);
    }

    #[test]
    fn test_parse_xspice_model_stored() {
        let c = parse_circuit(
            "test\nAinv (in) (out) MYINV\n\
             .model MYINV d_inverter (rise_delay=1n fall_delay=2n)\n\
             .end\n",
        );
        // Model should be stored with ModelKind::Other("d_inverter")
        let model = c.find_model("myinv");
        assert!(model.is_some());
        let (kind, params) = model.unwrap();
        assert_eq!(*kind, ModelKind::Other("d_inverter".to_string()));
        assert!(params.get("rise_delay").is_some());
    }

    #[test]
    fn test_parse_xspice_fixture_adc_bridge() {
        // Parse the actual xspice_adc_bridge.sp fixture file content
        let c = parse_circuit(
            "* XSPICE ADC bridge test\n\
             Vin in 0 PULSE(0 1.8 2n 8n 8n 10n 40n)\n\
             Rterm in 0 1MEG\n\
             Ainv (in) (vdigital) INVMOD\n\
             .model INVMOD d_inverter (rise_delay=0.1n fall_delay=0.1n input_load=0.01p)\n\
             Robs vdigital 0 10k\n\
             .tran 0.5n 40n\n\
             .end\n",
        );
        // Should have: Vin, Rterm, Ainv, Robs = 4 devices
        assert_eq!(c.devices().len(), 4);
        let a_dev = c.devices().iter().find(|d| d.kind == DeviceKind::Xspice).unwrap();
        assert_eq!(a_dev.terminal_count(), 2);
    }

    // ── SP / HB / PSS parsing tests ──────────────────────────────────────

    #[test]
    fn test_parse_sp_directive() {
        let netlist = "SP test\n\
            V1 in 0 dc 0 ac 1 portnum 1 z0 50\n\
            V2 out 0 dc 0 ac 0 portnum 2 z0 100\n\
            R1 in out 25\n\
            .sp lin 100 1e8 1e9\n\
            .end\n";
        let result = parse(netlist).unwrap();
        let sp = result.analyses.iter().find(|a| matches!(a,
            InternalAnalysisKind::Sp { .. } | InternalAnalysisKind::SParam { .. }
        ));
        assert!(sp.is_some(), "should parse .sp directive");
        match sp.unwrap() {
            InternalAnalysisKind::Sp { num_ports, sweep, fstart, fstop }
            | InternalAnalysisKind::SParam { num_ports, sweep, fstart, fstop } => {
                assert_eq!(*num_ports, 2, "should detect 2 ports");
                assert!(matches!(sweep, AcSweepType::Lin(100)));
                assert!((*fstart - 1e8).abs() < 1.0);
                assert!((*fstop - 1e9).abs() < 1.0);
            }
            _ => unreachable!(),
        }
    }

    #[test]
    fn test_parse_vsource_portnum_z0() {
        let netlist = "Port test\n\
            V1 in 0 dc 0 ac 1 portnum 1 z0 75\n\
            R1 in 0 50\n\
            .end\n";
        let result = parse(netlist).unwrap();
        let circuit = &result.circuit;
        let v1 = circuit.find_device("v1").expect("V1 not found");
        let portnum = v1.params.get("portnum").expect("portnum not set");
        assert!((portnum - 1.0).abs() < 1e-9, "portnum should be 1, got {portnum}");
        let z0 = v1.params.get("z0").expect("z0 not set");
        assert!((z0 - 75.0).abs() < 1e-9, "z0 should be 75, got {z0}");
        let ac_mag = v1.params.get("ac_mag").expect("ac_mag not set");
        assert!((ac_mag - 1.0).abs() < 1e-9, "ac_mag should be 1, got {ac_mag}");
    }

    #[test]
    fn test_parse_hb_directive() {
        let netlist = "HB test\n\
            V1 in 0 dc 0\n\
            R1 in 0 50\n\
            .hb fund=900Meg nharm=10\n\
            .end\n";
        let result = parse(netlist).unwrap();
        let hb = result.analyses.iter().find(|a| matches!(a,
            InternalAnalysisKind::Hb { .. } | InternalAnalysisKind::HarmonicBalance { .. }
        ));
        assert!(hb.is_some(), "should parse .hb directive");
        match hb.unwrap() {
            InternalAnalysisKind::Hb { fundamental, harmonics }
            | InternalAnalysisKind::HarmonicBalance { fundamental, harmonics } => {
                assert!((*fundamental - 900e6).abs() < 1e3, "fundamental should be 900MHz, got {fundamental}");
                assert_eq!(*harmonics, 10);
            }
            _ => unreachable!(),
        }
    }

    #[test]
    fn test_parse_pss_directive() {
        let netlist = "PSS test\n\
            V1 vdd 0 dc 1.8\n\
            R1 vdd 0 1k\n\
            .pss fund=1G harms=10\n\
            .end\n";
        let result = parse(netlist).unwrap();
        let pss = result.analyses.iter().find(|a| matches!(a,
            InternalAnalysisKind::Pss { .. }
        ));
        assert!(pss.is_some(), "should parse .pss directive");
        match pss.unwrap() {
            InternalAnalysisKind::Pss { fundamental } => {
                assert!((*fundamental - 1e9).abs() < 1e3, "fundamental should be 1GHz, got {fundamental}");
            }
            _ => unreachable!(),
        }
    }

    #[test]
    fn test_parse_sp_statement_conversion() {
        let netlist = "SP conv test\n\
            V1 in 0 dc 0 ac 1 portnum 1 z0 50\n\
            V2 out 0 dc 0 ac 0 portnum 2 z0 50\n\
            R1 in out 25\n\
            .sp dec 10 1e6 1e9\n\
            .end\n";
        let (_, analyses, _) = SpiceParser::parse_bytes(netlist.as_bytes()).unwrap();
        let sp = analyses.iter().find(|a| a.kind == AnalysisKind::Sp);
        assert!(sp.is_some(), "should produce SP AnalysisStatement");
        let sp = sp.unwrap();
        let num_ports = sp.params.iter().find(|(k, _)| k == "num_ports").map(|(_, v)| *v);
        assert_eq!(num_ports, Some(2.0));
    }
}
