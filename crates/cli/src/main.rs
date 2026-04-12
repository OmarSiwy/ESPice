use std::io::{self, Write};
use std::path::PathBuf;
use std::process::ExitCode;

use bigospice_analysis::{AcConfig, AcResult, AcSweepType, DcSweepConfig, TransientConfig,
                         TransientResult, run_ac, run_dc_op, run_dc_sweep, run_transient};
use bigospice_core::Circuit;
use bigospice_device::DeviceRegistry;
use bigospice_parser::{AnalysisKind, SpiceParser};

/// Output destination for simulation results.
enum OutputDest {
    None,
    Stdout,
    File(PathBuf),
}

/// Write DC OP results: one `node_name=value` per line.
fn write_dc_op<W: Write>(
    w: &mut W,
    node_voltages: &[(String, f64)],
    branch_currents: &[(String, f64)],
) -> io::Result<()> {
    for (name, val) in node_voltages {
        writeln!(w, "v({name})={val:.12e}")?;
    }
    for (name, val) in branch_currents {
        writeln!(w, "i({name})={val:.12e}")?;
    }
    Ok(())
}

/// Write transient results: tab-separated `time\tnode_name\tvalue` per line.
fn write_transient<W: Write>(
    w: &mut W,
    result: &TransientResult,
    node_names: &[String],
) -> io::Result<()> {
    for (step, &time) in result.times.iter().enumerate() {
        for (ni, name) in node_names.iter().enumerate() {
            let val = result.node_voltages_flat[step * result.num_nodes + ni];
            writeln!(w, "{time:.12e}\t{name}\t{val:.12e}")?;
        }
    }
    Ok(())
}

/// Write AC results: tab-separated `freq\tnode_name\tmag\tphase` per line.
fn write_ac<W: Write>(
    w: &mut W,
    result: &AcResult,
    node_names: &[String],
) -> io::Result<()> {
    for (fi, &freq) in result.frequencies.iter().enumerate() {
        for (ni, name) in node_names.iter().enumerate() {
            let mag = result.node_magnitudes[fi][ni];
            let phase = result.node_phases[fi][ni];
            writeln!(w, "{freq:.12e}\t{name}\t{mag:.12e}\t{phase:.12e}")?;
        }
    }
    Ok(())
}

/// Extract ordered node names from the circuit (excludes ground, ordered by matrix_index).
fn circuit_node_names(circuit: &Circuit) -> Vec<String> {
    let mut nodes: Vec<_> = circuit.nodes().iter()
        .filter_map(|n| n.matrix_index.map(|idx| (idx, n.name.clone())))
        .collect();
    nodes.sort_by_key(|(idx, _)| *idx);
    nodes.into_iter().map(|(_, name)| name).collect()
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    let mut path: Option<PathBuf> = None;
    let mut quiet = false;
    let mut output_dest = OutputDest::None;

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--no-output" => {} // kept for backwards compatibility: stays silent
            "--quiet" | "-q" => quiet = true,
            "--output" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("--output requires an argument (-  for stdout, or a file path)");
                    return ExitCode::FAILURE;
                }
                output_dest = match args[i].as_str() {
                    "-" => OutputDest::Stdout,
                    p   => OutputDest::File(PathBuf::from(p)),
                };
            }
            "-h" | "--help" => {
                eprintln!("Usage: bigospice [--output <file|-|>] [--quiet] <netlist.sp>");
                eprintln!("");
                eprintln!("  --output -        Write results to stdout");
                eprintln!("  --output <file>   Write results to file");
                eprintln!("  --quiet / -q      Suppress non-error messages");
                eprintln!("  --no-output       Suppress output (default, kept for compatibility)");
                return ExitCode::SUCCESS;
            }
            arg if !arg.starts_with('-') => path = Some(PathBuf::from(arg)),
            other => {
                eprintln!("unknown flag: {other}");
                return ExitCode::FAILURE;
            }
        }
        i += 1;
    }

    let path = match path {
        Some(p) => p,
        None => {
            eprintln!("Usage: bigospice [--output <file|->] [--quiet] <netlist.sp>");
            return ExitCode::FAILURE;
        }
    };

    let (circuit, analyses, _opts) = match SpiceParser::parse_file(&path) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("parse error: {e}");
            return ExitCode::FAILURE;
        }
    };

    // Open output writer once, before running analyses.
    let mut out_writer: Option<Box<dyn Write>> = match &output_dest {
        OutputDest::None => None,
        OutputDest::Stdout => Some(Box::new(io::BufWriter::new(io::stdout()))),
        OutputDest::File(p) => {
            match std::fs::File::create(p) {
                Ok(f) => Some(Box::new(io::BufWriter::new(f))),
                Err(e) => {
                    eprintln!("cannot open output file {}: {e}", p.display());
                    return ExitCode::FAILURE;
                }
            }
        }
    };

    let registry = DeviceRegistry::new_default();
    let mut ran = 0usize;

    for stmt in &analyses {
        let p = |key: &str| stmt.params.iter().find(|(k, _)| k == key).map(|(_, v)| *v);

        match &stmt.kind {
            AnalysisKind::DcOp => {
                match run_dc_op(&circuit, &registry) {
                    Ok(out) => {
                        if let Some(w) = out_writer.as_mut() {
                            if let Err(e) = write_dc_op(
                                w,
                                &out.result.node_voltages,
                                &out.result.branch_currents,
                            ) {
                                eprintln!("output error: {e}");
                                return ExitCode::FAILURE;
                            }
                        }
                        ran += 1;
                    }
                    Err(e) => {
                        eprintln!("simulation error: {e}");
                        return ExitCode::FAILURE;
                    }
                }
            }

            AnalysisKind::DcSweep => {
                let src_name = stmt.params.iter()
                    .find(|(k, _)| k.starts_with("__dc_src__"))
                    .map(|(k, _)| k["__dc_src__".len()..].to_string())
                    .unwrap_or_else(|| "v1".to_string());
                let start = p("start").unwrap_or(0.0);
                let stop  = p("stop").unwrap_or(1.0);
                let step  = p("step").unwrap_or(0.1);
                let cfg = DcSweepConfig::new(&src_name, start, stop, step);
                match run_dc_sweep(&circuit, &registry, &cfg) {
                    Ok(out) => {
                        if let Some(w) = out_writer.as_mut() {
                            if let Some(last_vals) = out.node_voltages.last() {
                                let node_names = circuit_node_names(&circuit);
                                let pairs: Vec<(String, f64)> = node_names.into_iter()
                                    .zip(last_vals.iter().copied())
                                    .collect();
                                if let Err(e) = write_dc_op(w, &pairs, &[] as &[(String, f64)]) {
                                    eprintln!("output error: {e}");
                                    return ExitCode::FAILURE;
                                }
                            }
                        }
                        ran += 1;
                    }
                    Err(e) => {
                        eprintln!("simulation error: {e}");
                        return ExitCode::FAILURE;
                    }
                }
            }

            AnalysisKind::Tran => {
                let tstep = p("tstep").unwrap_or(1e-9);
                let tstop = p("tstop").unwrap_or(1e-6);
                let cfg = TransientConfig::new(tstep, tstop);
                let mut c = circuit.clone();
                match run_transient(&mut c, &registry, &cfg) {
                    Ok(result) => {
                        if let Some(w) = out_writer.as_mut() {
                            let node_names = circuit_node_names(&circuit);
                            if let Err(e) = write_transient(w, &result, &node_names) {
                                eprintln!("output error: {e}");
                                return ExitCode::FAILURE;
                            }
                        }
                        ran += 1;
                    }
                    Err(e) => {
                        eprintln!("simulation error: {e}");
                        return ExitCode::FAILURE;
                    }
                }
            }

            AnalysisKind::Ac => {
                let sweep = match p("sweep_type").unwrap_or(1.0) as u8 {
                    0 => AcSweepType::Linear,
                    2 => AcSweepType::Octave,
                    _ => AcSweepType::Decade,
                };
                let npoints = p("npoints").unwrap_or(10.0) as usize;
                let fstart = p("fstart").unwrap_or(1.0);
                let fstop = p("fstop").unwrap_or(1e6);
                let cfg = AcConfig::new(fstart, fstop, npoints, sweep);
                match run_ac(&circuit, &registry, &cfg) {
                    Ok(result) => {
                        if let Some(w) = out_writer.as_mut() {
                            let node_names = circuit_node_names(&circuit);
                            if let Err(e) = write_ac(w, &result, &node_names) {
                                eprintln!("output error: {e}");
                                return ExitCode::FAILURE;
                            }
                        }
                        ran += 1;
                    }
                    Err(e) => {
                        eprintln!("simulation error: {e}");
                        return ExitCode::FAILURE;
                    }
                }
            }

            other => {
                if !quiet {
                    eprintln!("skip: {other:?}");
                }
                continue;
            }
        }
    }

    if ran == 0 {
        if !quiet {
            eprintln!("no supported analysis in netlist");
        }
        return ExitCode::FAILURE;
    }

    ExitCode::SUCCESS
}
