//! CLI orchestrator. Calls each crate's public API. Thin shell.
//!
//! Output: single function `print_output()` takes many Option params.
//! Non-None params get printed. Source of truth for all output formatting.

use std::fs::File;
use std::io::Write;
use std::path::PathBuf;
use std::process::ExitCode;

use clap::Parser as ClapParser;

use incspice_analysis::{self, Ac, Analysis, DcOp, DcSweep, EnvelopeFollowing, HarmonicBalance, MonteCarlo, NoiseAnalysis, Pss, Sensitivity, SpAnalysis, Transient};
use incspice_cache::{CacheManager, TopologyHash};
use incspice_core::{Circuit, NullSink, SimError, StreamingSink};
use incspice_parser::{AcSweepType, InternalAnalysisKind as AnalysisKind, SpiceParser};
use incspice_solver::device::DeviceRegistry;
use incspice_solver::newton::NrConfig;

mod io;
mod output;

// ── CLI args ──────────────────────────────────────────────────────────

/// Backend selector passed via --backend.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Backend {
    Native,
    Klu,
    Gpu,
}

impl std::str::FromStr for Backend {
    type Err = String;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.to_lowercase().as_str() {
            "native" => Ok(Backend::Native),
            "klu" => Ok(Backend::Klu),
            "gpu" => Ok(Backend::Gpu),
            other => Err(format!(
                "unknown backend '{other}'; valid: native, klu, gpu"
            )),
        }
    }
}

#[derive(ClapParser, Debug)]
#[command(
    name = "incspice",
    about = "Streaming SPICE simulator",
    version,
    long_about = "BigOSpice: streaming, data-oriented SPICE circuit simulator.\n\
                  Supports DC OP, DC sweep, transient, AC, noise, Fourier, FFT,\n\
                  harmonic balance (HB), PSS, PZ, TF, S-parameters (SP),\n\
                  Monte Carlo (MC), sensitivity, worst-case (.WCASE),\n\
                  envelope (.ENVLP), .ALTER, and .IF analyses."
)]
struct Args {
    /// Input SPICE netlist file.
    input: PathBuf,

    /// Output file path. Use '-' for stdout.
    #[arg(short, long)]
    output: Option<PathBuf>,

    /// Output format: raw (default), csv.
    #[arg(short, long, default_value = "raw")]
    format: String,

    /// Write binary rawfile instead of ASCII.
    #[arg(long)]
    binary: bool,

    /// Suppress non-error messages.
    #[arg(short, long)]
    quiet: bool,

    /// Linear algebra backend: native (default), klu, gpu.
    #[arg(long, default_value = "native")]
    backend: Backend,

    /// Number of worker threads (0 = use all available CPUs).
    #[arg(long, default_value_t = 0)]
    threads: usize,

    /// Verbose diagnostic output (topology hash, NR iterations, cache stats).
    #[arg(long)]
    verbose: bool,

    /// Disable incremental cache; always do full re-simulation.
    #[arg(long)]
    no_cache: bool,
}

// ── Main ──────────────────────────────────────────────────────────────

fn run(args: Args) -> Result<(), Box<dyn std::error::Error>> {
    // ── Backend selection ──────────────────────────────────────────────
    match args.backend {
        Backend::Native => {} // default, always available
        Backend::Klu => {
            #[cfg(not(feature = "klu"))]
            {
                eprintln!(
                    "warning: KLU backend requested but feature 'klu' not compiled in; \
                           falling back to native"
                );
            }
        }
        Backend::Gpu => {
            incspice_solver::check_gpu_available()
                .map_err(|e| Box::new(e) as Box<dyn std::error::Error>)?;
        }
    }

    // ── Thread pool (§16) ─────────────────────────────────────────────
    // threads == 0 means "use all CPUs"; Rayon treats num_threads(0) as
    // "use all available", so we can pass the raw value directly.
    let thread_count = if args.threads == 0 {
        std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(1)
    } else {
        args.threads
    };

    if let Some(n) = Some(thread_count).filter(|_| args.threads != 0) {
        rayon::ThreadPoolBuilder::new()
            .num_threads(n)
            .build_global()
            .unwrap_or_else(|e| eprintln!("Warning: failed to set thread count: {e}"));
    }

    // ── Stage 1: Parse (crates/parser) ────────────────────────────────
    let contents = std::fs::read(&args.input)?;
    let parsed = SpiceParser::parse_netlist(&contents)?;
    let mut circuit = parsed.circuit;
    let analyses = parsed.analyses;
    let options = parsed.options;

    if !args.quiet {
        output::print_output(output::OutputParams {
            parse_nodes: Some(circuit.nodes().len()),
            parse_devices: Some(circuit.devices().len()),
            parse_analyses: Some(analyses.len()),
            ..Default::default()
        });
    }

    // ── Stage 2: Topology (crates/core) ───────────────────────────────
    circuit.build_topology();

    if args.verbose {
        let hash = TopologyHash::from_circuit(&circuit).0;
        output::print_output(output::OutputParams {
            topology_hash: Some(hash),
            ..Default::default()
        });
    }

    // ── Stage 3: Device registry (crates/solver::device) ──────────────
    let registry = DeviceRegistry::new_default();

    // ── Stage 4: Cache (crates/cache) ─────────────────────────────────
    let mut cache = CacheManager::new();
    if !args.no_cache {
        cache.on_topology_built(&circuit);
    }

    // ── Stage 5: NR config from .OPTIONS (crates/solver) ──────────────
    let core_opts = {
        let mut o = incspice_core::SimOptions::default();
        if let Some(v) = options.reltol {
            o.reltol = v;
        }
        if let Some(v) = options.abstol {
            o.abstol = v;
        }
        if let Some(v) = options.vntol {
            o.vntol = v;
        }
        if let Some(v) = options.gmin {
            o.gmin = v;
        }
        o
    };
    let nr_config = NrConfig::from_options(&core_opts);

    // ── Stage 6: Dispatch analyses (crates/analysis) ──────────────────
    //
    // STREAMING PIPELINE:
    //   [Main/Solver] --emit_point()--> [channel(4)] --> [Writer Thread] --> disk
    //
    // NullSink is used when no output file is requested.
    //
    for analysis_kind in &analyses {
        let analysis: Box<dyn Analysis> = build_analysis(analysis_kind, &args)?;

        match &args.output {
            Some(path) => {
                // Resolve stdout alias
                let file_sink: Box<dyn StreamingSink + Send> = if path.as_os_str() == "-" {
                    match args.format.as_str() {
                        "csv" => {
                            Box::new(output::csv_sink_for_circuit(std::io::stdout(), &circuit))
                        }
                        _ => {
                            // rawfile requires Seek; stdout is not seekable.
                            // Fall back to CSV when writing to stdout.
                            eprintln!(
                                "note: rawfile format requires a seekable output; \
                                       writing CSV to stdout instead"
                            );
                            Box::new(output::csv_sink_for_circuit(std::io::stdout(), &circuit))
                        }
                    }
                } else {
                    let file = File::create(path)?;
                    match args.format.as_str() {
                        "csv" => Box::new(output::csv_sink_for_circuit(file, &circuit)),
                        _ => Box::new(output::rawfile_sink_for_circuit(file, &circuit)?),
                    }
                };

                let (mut channel_sink, writer_handle) =
                    output::spawn_streaming_pipeline(file_sink, 4);

                analysis.run(
                    &mut circuit,
                    &registry,
                    &nr_config,
                    &mut cache,
                    &mut channel_sink,
                )?;

                // §17: improved writer-thread panic diagnostic
                writer_handle
                    .join()
                    .map_err(|e| {
                        let msg = e.downcast_ref::<String>()
                            .map(|s| s.as_str())
                            .or_else(|| e.downcast_ref::<&str>().copied())
                            .unwrap_or("<unknown panic payload>");
                        format!("writer thread panicked: {msg}")
                    })?
                    .map_err(|e| format!("writer I/O error: {e}"))?;

                if !args.quiet {
                    output::print_output(output::OutputParams {
                        output_file: Some(path.display().to_string()),
                        output_format: Some(args.format.clone()),
                        ..Default::default()
                    });
                }
            }
            None => {
                let mut sink = NullSink;
                analysis.run(&mut circuit, &registry, &nr_config, &mut cache, &mut sink)?;
            }
        }

        if !args.quiet {
            output::print_output(output::OutputParams {
                analysis_name: Some(analysis.name().to_string()),
                analysis_done: Some(true),
                ..Default::default()
            });
        }
    }

    // Default DC OP when netlist has no analysis directives
    if analyses.is_empty() {
        let mut sink = NullSink;
        DcOp.run(&mut circuit, &registry, &nr_config, &mut cache, &mut sink)?;
        if !args.quiet {
            output::print_output(output::OutputParams {
                analysis_name: Some("dc_op (default)".into()),
                analysis_done: Some(true),
                ..Default::default()
            });
        }
    }

    let _ = thread_count; // suppress unused-variable warning when threads==0
    Ok(())
}

/// Build a concrete `Analysis` implementation from a parsed `AnalysisKind`.
///
/// Every SPICE analysis type known to the parser is handled here.
/// Analyses that have a real `Analysis`-trait implementation are wired up
/// directly.  Analyses whose modules only expose lower-level `run_*` helpers
/// (not the `Analysis` trait) return `Err(SimError::Unimplemented)` so the
/// caller gets a clear error instead of silently falling back to DC OP.
fn build_analysis(kind: &AnalysisKind, args: &Args) -> Result<Box<dyn Analysis>, SimError> {
    match kind {
        // ── Implemented analyses ──────────────────────────────────────
        AnalysisKind::DcOp => Ok(Box::new(DcOp)),

        AnalysisKind::DcSweep {
            source,
            start,
            stop,
            step,
            source2,
            start2,
            stop2,
            step2,
        } => Ok(Box::new(DcSweep {
            source: source.clone(),
            values: sweep_values(*start, *stop, *step),
            source2: source2.clone(),
            values2: if source2.is_some() {
                sweep_values(*start2, *stop2, *step2)
            } else {
                vec![]
            },
        })),

        AnalysisKind::Transient { tstep, tstop, .. } => Ok(Box::new(Transient {
            tstep: *tstep,
            tstop: *tstop,
        })),

        AnalysisKind::Ac {
            sweep,
            fstart,
            fstop,
        } => Ok(Box::new(Ac {
            frequencies: ac_freqs(sweep, *fstart, *fstop),
        })),

        // ── Analyses with Analysis-trait stubs ────────────────────────

        AnalysisKind::HarmonicBalance { fundamental, harmonics }
        | AnalysisKind::Hb { fundamental, harmonics } => Ok(Box::new(HarmonicBalance {
            fundamental: *fundamental,
            harmonics: *harmonics,
        })),

        AnalysisKind::Pss { fundamental } => Ok(Box::new(Pss {
            fundamental_freq: *fundamental,
            ..Pss::default()
        })),

        AnalysisKind::MonteCarlo { num_samples }
        | AnalysisKind::Mc { num_samples } => Ok(Box::new(MonteCarlo {
            num_samples: *num_samples,
        })),

        AnalysisKind::Sensitivity { .. } => Ok(Box::new(Sensitivity {
            output: match kind {
                AnalysisKind::Sensitivity { output } => output.clone(),
                _ => String::new(),
            },
        })),

        // ── Analyses not yet wired to the Analysis trait ──────────────
        // These modules expose `run_*` helpers but no `impl Analysis for …`.
        // Return Unimplemented so the caller sees a clear diagnostic rather
        // than silently running a wrong analysis.

        AnalysisKind::Noise { output, source, sweep, fstart, fstop, npoints } => {
            use incspice_parser::AcSweepType as PSweep;
            use incspice_analysis::AcSweepType as ASweep;
            let asweep = match sweep {
                PSweep::Lin(_) => ASweep::Linear,
                PSweep::Dec(_) => ASweep::Decade,
                PSweep::Oct(_) => ASweep::Octave,
            };
            Ok(Box::new(NoiseAnalysis {
                output_node: output.clone(),
                input_source: source.clone(),
                sweep: asweep,
                fstart: *fstart,
                fstop: *fstop,
                npoints: *npoints,
            }))
        }

        AnalysisKind::Fourier { .. } => Err(SimError::Unimplemented {
            analysis: "FOUR".to_string(),
        }),

        AnalysisKind::Fft { .. } => Err(SimError::Unimplemented {
            analysis: "FFT".to_string(),
        }),

        AnalysisKind::PoleZero { .. } => Err(SimError::Unimplemented {
            analysis: "PZ".to_string(),
        }),

        AnalysisKind::TransferFunction { .. } => Err(SimError::Unimplemented {
            analysis: "TF".to_string(),
        }),

        AnalysisKind::SParam { sweep, fstart, fstop, .. }
        | AnalysisKind::Sp { sweep, fstart, fstop, .. } => {
            use incspice_parser::AcSweepType as PSweep;
            use incspice_analysis::AcSweepType as ASweep;
            let (asweep, npoints) = match sweep {
                PSweep::Lin(n) => (ASweep::Linear, *n),
                PSweep::Dec(n) => (ASweep::Decade, *n),
                PSweep::Oct(n) => (ASweep::Octave, *n),
            };
            Ok(Box::new(SpAnalysis {
                sweep_type: asweep,
                freq_start: *fstart,
                freq_stop: *fstop,
                num_points: npoints,
            }))
        }

        AnalysisKind::WorstCase { .. } => Err(SimError::Unimplemented {
            analysis: "WCASE".to_string(),
        }),

        AnalysisKind::Envelope { fund, tstop, tstep } => Ok(Box::new(EnvelopeFollowing {
            fund: *fund,
            tstop: *tstop,
            tstep: *tstep,
        })),

        AnalysisKind::Alter { .. } => Err(SimError::Unimplemented {
            analysis: "ALTER".to_string(),
        }),

        // ── .IF conditional block ─────────────────────────────────────
        // .IF is resolved at parse time; the parser should never emit it as
        // an analysis kind in normal operation. Handle gracefully.
        AnalysisKind::If { .. } => {
            if !args.quiet {
                eprintln!("note: .IF analysis kind encountered (parser artefact — skipped)");
            }
            Ok(Box::new(DcOp))
        }

        // ── Unknown / future ──────────────────────────────────────────
        other => {
            if !args.quiet {
                eprintln!("warning: unrecognised analysis kind {other:?} — falling back to DC OP");
            }
            Ok(Box::new(DcOp))
        }
    }
}

// ── Sweep helpers ─────────────────────────────────────────────────────

fn sweep_values(start: f64, stop: f64, step: f64) -> Vec<f64> {
    let mut v = Vec::new();
    if step == 0.0 {
        return v;
    }
    let eps = step.abs() * 1e-9;
    let asc = step > 0.0;
    let mut x = start;
    while if asc {
        x <= stop + eps
    } else {
        x >= stop - eps
    } {
        v.push(x);
        x += step;
    }
    v
}

fn ac_freqs(sweep: &AcSweepType, fstart: f64, fstop: f64) -> Vec<f64> {
    match sweep {
        AcSweepType::Lin(n) => (0..*n)
            .map(|i| fstart + (fstop - fstart) * i as f64 / (*n - 1).max(1) as f64)
            .collect(),
        AcSweepType::Dec(ppd) => {
            let mut fs = Vec::new();
            let mut f = fstart;
            let r = 10.0_f64.powf(1.0 / *ppd as f64);
            while f <= fstop * 1.000_000_001 {
                fs.push(f);
                f *= r;
            }
            fs
        }
        AcSweepType::Oct(ppo) => {
            let mut fs = Vec::new();
            let mut f = fstart;
            let r = 2.0_f64.powf(1.0 / *ppo as f64);
            while f <= fstop * 1.000_000_001 {
                fs.push(f);
                f *= r;
            }
            fs
        }
    }
}

fn main() -> ExitCode {
    match run(Args::parse()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("error: {e}");
            ExitCode::FAILURE
        }
    }
}
