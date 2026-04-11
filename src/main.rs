use std::path::PathBuf;
use std::process::ExitCode;

use bigospice_analysis::{AcConfig, AcSweepType, TransientConfig, run_ac, run_dc_op, run_transient};
use bigospice_device::DeviceRegistry;
use bigospice_parser::{AnalysisKind, SpiceParser};

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    let mut path: Option<PathBuf> = None;
    let mut quiet = false;

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--no-output" => {} // reserved: output writing not yet implemented
            "--quiet" | "-q" => quiet = true,
            "-h" | "--help" => {
                eprintln!("Usage: bigospice [--no-output] [--quiet] <netlist.sp>");
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
            eprintln!("Usage: bigospice [--no-output] [--quiet] <netlist.sp>");
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

    let registry = DeviceRegistry::new_default();
    let mut ran = 0usize;

    for stmt in &analyses {
        let p = |key: &str| stmt.params.iter().find(|(k, _)| k == key).map(|(_, v)| *v);

        let result = match &stmt.kind {
            AnalysisKind::DcOp => run_dc_op(&circuit, &registry).map(|_| ()),

            AnalysisKind::Tran => {
                let tstep = p("tstep").unwrap_or(1e-9);
                let tstop = p("tstop").unwrap_or(1e-6);
                let cfg = TransientConfig::new(tstep, tstop);
                let mut c = circuit.clone();
                run_transient(&mut c, &registry, &cfg).map(|_| ())
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
                run_ac(&circuit, &registry, &cfg).map(|_| ())
            }

            other => {
                if !quiet {
                    eprintln!("skip: {other:?}");
                }
                continue;
            }
        };

        match result {
            Ok(()) => ran += 1,
            Err(e) => {
                eprintln!("simulation error: {e}");
                return ExitCode::FAILURE;
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
