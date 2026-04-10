use clap::Parser;
use std::path::{Path, PathBuf};
use pisim_test_harness::config::{discover_tests, ExternalSuite, TestConfig};
use pisim_test_harness::golden::GoldenData;
use pisim_test_harness::ngspice::NgspiceConfig;

#[derive(Parser)]
#[command(name = "generate-goldens")]
#[command(about = "Generate golden reference CSVs from ngspice simulation results")]
struct Args {
    /// Filter tests by tag (comma-separated)
    #[arg(long, value_delimiter = ',')]
    tags: Vec<String>,

    /// Run only the named test
    #[arg(long)]
    name: Option<String>,

    /// Run against an external suite (e.g., "ngspice")
    #[arg(long)]
    suite: Option<String>,

    /// Root directory for test discovery
    #[arg(long, default_value = "tests/regression/suites")]
    root: PathBuf,

    /// External suites directory
    #[arg(long, default_value = "tests/external")]
    external_root: PathBuf,

    /// Show what would be generated without writing
    #[arg(long)]
    dry_run: bool,

    /// Overwrite existing golden files
    #[arg(long)]
    force: bool,
}

fn main() {
    let args = Args::parse();

    let ngspice = NgspiceConfig::default();
    if !ngspice.is_available() {
        eprintln!("ERROR: ngspice not found. Install ngspice or set NGSPICE_BIN.");
        std::process::exit(1);
    }

    let configs = if let Some(ref suite_name) = args.suite {
        discover_external_suite(suite_name, &args.external_root)
    } else {
        discover_tests(&args.root, &args.tags)
    };

    let configs: Vec<TestConfig> = if let Some(ref name) = args.name {
        configs.into_iter().filter(|c| c.test.name == *name).collect()
    } else {
        configs
    };

    if configs.is_empty() {
        eprintln!("No test configurations found.");
        std::process::exit(1);
    }

    let mut generated = 0;
    let mut skipped = 0;
    let mut failed = 0;

    for config in &configs {
        let golden_path = match config.golden_path() {
            Some(p) => p,
            None => {
                eprintln!("  SKIP {}: no golden path defined", config.test.name);
                skipped += 1;
                continue;
            }
        };

        if golden_path.exists() && !args.force {
            eprintln!("  SKIP {}: golden exists (use --force to overwrite)", config.test.name);
            skipped += 1;
            continue;
        }

        if args.dry_run {
            println!("  WOULD generate: {} -> {}", config.test.name, golden_path.display());
            skipped += 1;
            continue;
        }

        let netlist_path = config.netlist_path();
        if !netlist_path.exists() {
            eprintln!("  FAIL {}: netlist not found: {}", config.test.name, netlist_path.display());
            failed += 1;
            continue;
        }

        print!("  GEN  {}...", config.test.name);
        match ngspice.run(&netlist_path) {
            Ok(result) => {
                let golden = GoldenData::from_rawfile(&result.rawfile);
                if let Some(parent) = golden_path.parent() {
                    std::fs::create_dir_all(parent).ok();
                }
                match golden.write_csv(&golden_path) {
                    Ok(()) => {
                        println!(" OK ({:.1}ms)", result.wall_time.as_secs_f64() * 1000.0);
                        generated += 1;
                    }
                    Err(e) => {
                        println!(" FAIL (write: {e})");
                        failed += 1;
                    }
                }
            }
            Err(e) => {
                println!(" FAIL (ngspice: {e})");
                failed += 1;
            }
        }
    }

    println!();
    println!("=== Golden Generation Summary ===");
    println!("Generated: {generated}  Skipped: {skipped}  Failed: {failed}");

    if failed > 0 {
        std::process::exit(1);
    }
}

fn discover_external_suite(name: &str, external_root: &Path) -> Vec<TestConfig> {
    let (root, glob_pattern) = match name {
        "ngspice" => (
            external_root.join("ngspice/tests"),
            "**/*.cir".to_string(),
        ),
        "xyce_regression" => (
            external_root.join("xyce_regression/Netlists"),
            "**/*.cir".to_string(),
        ),
        other => {
            eprintln!("Unknown suite: {other}. Known suites: ngspice, xyce_regression");
            std::process::exit(1);
        }
    };

    let suite = ExternalSuite {
        name: name.to_string(),
        root,
        netlist_glob: glob_pattern,
        default_tags: vec!["external".to_string()],
    };
    suite.discover()
}
