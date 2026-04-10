//! PiSIM vs ngspice timing benchmark.
//! Runs the same DC OP circuits through both simulators, compares results and wall-clock time.
//! Run with: cargo test --test ngspice_bench -- --include-ignored --nocapture

use std::path::Path;
use std::time::Instant;
use pisim_test_harness::{parse_netlist_file, run_dc_op, NgspiceConfig, Tolerance};

fn project_root() -> &'static Path {
    Path::new(env!("CARGO_MANIFEST_DIR"))
}

enum BenchResult {
    Ok {
        name: String,
        pisim_us: f64,
        ngspice_us: f64,
        speedup: f64,
        signals: usize,
        max_abs_err: f64,
        pass: bool,
    },
    PisimFailed {
        name: String,
        ngspice_us: f64,
        error: String,
    },
    NgspiceFailed {
        name: String,
        error: String,
    },
    NoNgspice,
}

fn bench_dc_op(fixture_path: &Path, name: &str, tol: &Tolerance) -> BenchResult {
    let ngspice = NgspiceConfig::default();
    if !ngspice.is_available() {
        return BenchResult::NoNgspice;
    }

    // --- ngspice ---
    let _ = ngspice.run(fixture_path); // warmup
    let ng_start = Instant::now();
    let ng_result = match ngspice.run(fixture_path) {
        Ok(r) => r,
        Err(e) => return BenchResult::NgspiceFailed {
            name: name.to_string(),
            error: format!("{e}"),
        },
    };
    let ngspice_us = ng_start.elapsed().as_secs_f64() * 1e6;
    let ng_pairs = ng_result.rawfile.as_dc_pairs();

    // --- PiSIM ---
    let (circuit, _) = parse_netlist_file(fixture_path).unwrap();
    let _ = run_dc_op(&circuit); // warmup
    let pisim_start = Instant::now();
    let pi_result = match run_dc_op(&circuit) {
        Ok(r) => r,
        Err(e) => return BenchResult::PisimFailed {
            name: name.to_string(),
            ngspice_us,
            error: format!("{e}"),
        },
    };
    let pisim_us = pisim_start.elapsed().as_secs_f64() * 1e6;

    // Build PiSIM pairs
    let mut pi_pairs: Vec<(String, f64)> = Vec::new();
    for (n, v) in &pi_result.node_voltages {
        pi_pairs.push((format!("v({})", n), *v));
    }
    for (n, v) in &pi_result.branch_currents {
        pi_pairs.push((format!("i({})", n.to_lowercase()), *v));
    }

    // --- Compare ---
    let mut max_abs_err: f64 = 0.0;
    let mut all_pass = true;
    let mut compared = 0;

    for (ng_name, ng_val) in &ng_pairs {
        let ng_lower = ng_name.to_lowercase();
        if !ng_lower.starts_with("v(") && !ng_lower.starts_with("i(") {
            continue;
        }

        if let Some((_, pi_val)) = pi_pairs.iter().find(|(n, _)| n.to_lowercase() == ng_lower) {
            let abs_err = (pi_val - ng_val).abs();
            max_abs_err = max_abs_err.max(abs_err);
            compared += 1;

            let is_current = ng_lower.starts_with("i(");
            let (abs_tol, rel_tol) = if is_current {
                tol.dc_current
            } else {
                tol.dc_voltage
            };
            if !Tolerance::within(*pi_val, *ng_val, abs_tol, rel_tol) {
                all_pass = false;
            }
        }
    }

    let speedup = ngspice_us / pisim_us;

    BenchResult::Ok {
        name: name.to_string(),
        pisim_us,
        ngspice_us,
        speedup,
        signals: compared,
        max_abs_err,
        pass: all_pass,
    }
}

#[test]
#[ignore = "ngspice benchmark — run with --include-ignored --nocapture"]
fn bench_pisim_vs_ngspice() {
    let root = project_root();
    let tol = Tolerance::default();
    let relaxed_tol = Tolerance {
        dc_voltage: (1e-3, 1e-3),
        dc_current: (1e-9, 1e-3),
        ..Tolerance::default()
    };

    let fixtures: Vec<(&str, &str, &Tolerance)> = vec![
        ("voltage_divider", "tests/fixtures/basic/voltage_divider.sp", &tol),
        ("three_resistor_chain", "tests/fixtures/basic/three_resistor_chain.sp", &tol),
        ("cmos_inverter", "tests/fixtures/basic/cmos_inverter.sp", &relaxed_tol),
        ("diff_pair", "tests/fixtures/basic/diff_pair.sp", &relaxed_tol),
        ("current_mirror", "tests/fixtures/basic/current_mirror.sp", &relaxed_tol),
    ];

    let mut results: Vec<BenchResult> = Vec::new();

    for (name, rel_path, t) in &fixtures {
        let path = root.join(rel_path);
        if !path.exists() {
            eprintln!("SKIP {name}: fixture not found");
            continue;
        }
        let r = bench_dc_op(&path, name, t);
        if matches!(r, BenchResult::NoNgspice) {
            eprintln!("ngspice not available — skipping all benchmarks");
            return;
        }
        results.push(r);
    }

    // Print results table
    println!();
    println!("╔══════════════════════════╦══════════════╦══════════════╦══════════╦══════════╦══════════════╦════════╗");
    println!("║ Circuit                  ║  PiSIM (us)  ║ ngspice (us) ║ Speedup  ║ Signals  ║ Max Abs Err  ║ Match  ║");
    println!("╠══════════════════════════╬══════════════╬══════════════╬══════════╬══════════╬══════════════╬════════╣");

    for r in &results {
        match r {
            BenchResult::Ok { name, pisim_us, ngspice_us, speedup, signals, max_abs_err, pass } => {
                println!(
                    "║ {:<24} ║ {:>10.1}  ║ {:>10.1}  ║ {:>6.1}x  ║ {:>6}   ║ {:>10.2e}  ║  {}  ║",
                    name, pisim_us, ngspice_us, speedup, signals, max_abs_err,
                    if *pass { "PASS" } else { "FAIL" },
                );
            }
            BenchResult::PisimFailed { name, ngspice_us, error } => {
                println!(
                    "║ {:<24} ║     FAIL     ║ {:>10.1}  ║   N/A    ║   N/A    ║     N/A      ║  {:4}  ║",
                    name, ngspice_us, "ERR",
                );
                eprintln!("  PiSIM error on {name}: {error}");
            }
            BenchResult::NgspiceFailed { name, error } => {
                println!(
                    "║ {:<24} ║     N/A      ║     FAIL     ║   N/A    ║   N/A    ║     N/A      ║  {:4}  ║",
                    name, "SKIP",
                );
                eprintln!("  ngspice error on {name}: {error}");
            }
            BenchResult::NoNgspice => unreachable!(),
        }
    }

    println!("╚══════════════════════════╩══════════════╩══════════════╩══════════╩══════════╩══════════════╩════════╝");

    // Summary
    let mut total_pi: f64 = 0.0;
    let mut total_ng: f64 = 0.0;
    let mut passed = 0;
    let mut compared = 0;

    for r in &results {
        if let BenchResult::Ok { pisim_us, ngspice_us, pass, .. } = r {
            total_pi += pisim_us;
            total_ng += ngspice_us;
            compared += 1;
            if *pass { passed += 1; }
        }
    }

    println!();
    if compared > 0 {
        println!("Total PiSIM:   {:.0} us", total_pi);
        println!("Total ngspice: {:.0} us", total_ng);
        println!("Overall:       {:.1}x speedup", total_ng / total_pi);
    }
    println!("Accuracy:      {passed}/{} circuits match within tolerance", results.len());
    println!("Converged:     {compared}/{} circuits solved by PiSIM", results.len());
}
