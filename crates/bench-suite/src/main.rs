//! `pisim-bench` — head-to-head benchmark CLI.

use clap::Parser;
use std::path::PathBuf;

use pisim_bench_suite::{perf::run_head_to_head, Analysis, BenchReport};

#[derive(Debug, Parser)]
#[command(
    name = "pisim-bench",
    about = "Head-to-head accuracy + performance benchmarks vs ngspice"
)]
struct Cli {
    /// Path to a SPICE netlist (.sp / .cir).
    #[arg(long)]
    netlist: PathBuf,

    /// Analysis to drive: dc, ac, tran.
    #[arg(long)]
    analysis: String,

    /// Number of timing runs per simulator.
    #[arg(long, default_value_t = 5)]
    nruns: usize,

    /// Also run ngspice and compare accuracy + speed.
    #[arg(long, default_value_t = false)]
    with_ngspice: bool,

    /// Optional path to write a JSON report.
    #[arg(long)]
    report: Option<PathBuf>,
}

fn main() {
    let cli = Cli::parse();
    let analysis: Analysis = cli.analysis.parse().unwrap_or_else(|e| {
        eprintln!("invalid --analysis: {e}");
        std::process::exit(2);
    });

    let (perf, accuracy, pstatus, ngstatus) =
        run_head_to_head(&cli.netlist, analysis, cli.nruns, cli.with_ngspice);

    let report = BenchReport {
        netlist: cli.netlist.display().to_string(),
        analysis: format!("{:?}", analysis),
        pisim_status: pstatus,
        ngspice_status: ngstatus,
        perf,
        accuracy,
    };

    println!("=== pisim-bench ===");
    println!("netlist : {}", report.netlist);
    println!("analysis: {}", report.analysis);
    println!("pisim   : {}", report.pisim_status);
    println!("ngspice : {}", report.ngspice_status);
    println!(
        "pisim    median = {:>10.6} s   (min {:.6} max {:.6}  N={})",
        report.perf.pisim.median_secs,
        report.perf.pisim.min_secs,
        report.perf.pisim.max_secs,
        report.perf.pisim.n_runs
    );
    if let Some(ng) = &report.perf.ngspice {
        println!(
            "ngspice  median = {:>10.6} s   (min {:.6} max {:.6}  N={})",
            ng.median_secs, ng.min_secs, ng.max_secs, ng.n_runs
        );
    }
    if let Some(r) = report.perf.ratio_pisim_over_ngspice {
        let speedup = if r > 0.0 { 1.0 / r } else { f64::NAN };
        println!(
            "ratio pisim/ngspice = {:.4}  ({:.2}x speedup vs ngspice)",
            r, speedup
        );
    }
    if let Some(acc) = &report.accuracy {
        println!(
            "accuracy: max_abs={:.3e}  max_rel={:.3e}  rmse={:.3e}  signals={}  points={}",
            acc.max_abs_err, acc.max_rel_err, acc.rmse, acc.n_signals, acc.n_points
        );
        let labels = ["1e-6", "1e-4", "1e-3", "1e-2"];
        for (l, p) in labels.iter().zip(acc.pass_matrix.iter()) {
            println!("  tol {l}: {}", if *p { "PASS" } else { "FAIL" });
        }
        if !acc.note.is_empty() {
            println!("  note: {}", acc.note);
        }
    }

    if let Some(out) = cli.report.as_ref() {
        match serde_json::to_string_pretty(&report) {
            Ok(s) => {
                if let Err(e) = std::fs::write(out, s) {
                    eprintln!("failed to write report: {e}");
                    std::process::exit(1);
                }
                println!("report written to {}", out.display());
            }
            Err(e) => {
                eprintln!("failed to serialize report: {e}");
                std::process::exit(1);
            }
        }
    }
}
