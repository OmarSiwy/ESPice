//! GPU/CPU auto-dispatch tests for batch BSIM4 device evaluation.
//!
//! Builds a synthetic ladder of `N` BSIM4 devices and exercises
//! `pisim_solver::eval_bsim4_batch` for `N ∈ {16, 128, 2048}`.
//!
//! Assertions:
//! 1. `N = 16` is below the default threshold → `should_use_gpu`
//!    must return `false`.  CPU result is the reference.
//! 2. `N = 2048` is well above the default threshold → if a GPU
//!    adapter is available, `should_use_gpu` must return `true`
//!    and `eval_bsim4_batch` (with the auto-dispatch policy) must
//!    return numbers that match the CPU forced-fallback to within
//!    `1e-6` relative tolerance.
//! 3. When no GPU adapter is available the GPU paths skip
//!    gracefully (the test passes by reporting "no GPU, skipped").
//!
//! These tests are marked `#[ignore]` because they exercise the
//! optional GPU path; CI invokes them with `--include-ignored`.

use pisim_device::bsim4::{Bsim4Geometry, Bsim4Instance, Bsim4Model};
use pisim_solver::{eval_bsim4_batch, should_use_gpu, NrConfig, DEFAULT_GPU_DEVICE_THRESHOLD};

/// Build a homogeneous ladder of `n` NMOS instances and matching
/// (Vd, Vg, Vs, Vb) tuples.  The Vgs sweep keeps every device in a
/// distinct operating point so any per-element bug shows up.
fn build_ladder(n: usize) -> (Vec<Bsim4Instance>, Vec<(f64, f64, f64, f64)>) {
    let model = Bsim4Model::nmos_default();
    let geom = Bsim4Geometry {
        L: 1.0e-7,
        W: 1.0e-6,
        ..Default::default()
    };
    let inst = Bsim4Instance::from_model(&model, &geom, 300.15);
    let instances = vec![inst; n];

    let voltages: Vec<(f64, f64, f64, f64)> = (0..n)
        .map(|i| {
            let vgs = 0.6 + (i as f64 % 16.0) * 0.025;
            (1.0, vgs, 0.0, 0.0)
        })
        .collect();

    (instances, voltages)
}

#[test]
#[ignore = "exercises the optional GPU dispatch policy; run with --include-ignored"]
fn gpu_dispatch_small_n_uses_cpu() {
    let n = 16;
    let cfg = NrConfig::default();
    assert!(
        n < DEFAULT_GPU_DEVICE_THRESHOLD,
        "test assumes default threshold is > 16",
    );
    assert!(
        !should_use_gpu(&cfg, n),
        "N=16 must take the CPU path under the default policy",
    );

    let (instances, voltages) = build_ladder(n);
    let out = eval_bsim4_batch(&cfg, &instances, &voltages);
    assert_eq!(out.len(), n);
    // Sanity-check: first device should have a positive drain current
    // (NMOS in mild inversion at Vgs ≈ 0.6).
    assert!(out[0].ids >= 0.0);
}

#[test]
#[ignore = "exercises the optional GPU dispatch policy; run with --include-ignored"]
fn gpu_dispatch_medium_n_uses_cpu() {
    let n = 128;
    let cfg = NrConfig::default();
    assert!(n < DEFAULT_GPU_DEVICE_THRESHOLD);
    assert!(!should_use_gpu(&cfg, n));

    let (instances, voltages) = build_ladder(n);
    let out = eval_bsim4_batch(&cfg, &instances, &voltages);
    assert_eq!(out.len(), n);
}

#[test]
#[ignore = "exercises the optional GPU dispatch policy; run with --include-ignored"]
fn gpu_dispatch_large_n_uses_gpu_when_available() {
    let n = 2048;
    let cfg = NrConfig::default();

    assert!(
        n >= DEFAULT_GPU_DEVICE_THRESHOLD,
        "test assumes default threshold is <= 2048",
    );
    assert!(
        should_use_gpu(&cfg, n),
        "N=2048 must take the GPU path under the default policy",
    );

    let gpu_available = pisim_compute::WgpuBackend::is_available();
    eprintln!(
        "gpu_dispatch_large_n: N={n} threshold={} gpu_available={gpu_available}",
        DEFAULT_GPU_DEVICE_THRESHOLD,
    );

    let (instances, voltages) = build_ladder(n);

    // Reference: force CPU path.
    let cfg_cpu = NrConfig {
        use_gpu: Some(false),
        ..NrConfig::default()
    };
    let cpu = eval_bsim4_batch(&cfg_cpu, &instances, &voltages);

    // Auto-dispatch (will use GPU when adapter is available; otherwise
    // gracefully falls back to CPU and emits a `log::warn!`).
    let auto = eval_bsim4_batch(&cfg, &instances, &voltages);

    assert_eq!(cpu.len(), n);
    assert_eq!(auto.len(), n);

    // CPU vs auto match check — required to be within 1e-6 relative.
    let mut max_rel = 0.0_f64;
    for (a, b) in cpu.iter().zip(auto.iter()) {
        let denom = a.ids.abs().max(1e-18);
        let rel = (a.ids - b.ids).abs() / denom;
        if rel > max_rel {
            max_rel = rel;
        }
    }
    eprintln!("gpu_dispatch_large_n: max relative Ids error = {max_rel:.3e}");
    assert!(
        max_rel <= 1.0e-6,
        "CPU vs auto-dispatch BSIM4 batch mismatch: max_rel={max_rel:.3e}",
    );
}

#[test]
#[ignore = "exercises the optional GPU dispatch policy; run with --include-ignored"]
fn gpu_dispatch_force_off_overrides_threshold() {
    let n = 4096;
    let cfg = NrConfig {
        use_gpu: Some(false),
        ..NrConfig::default()
    };
    assert!(!should_use_gpu(&cfg, n));
    let (instances, voltages) = build_ladder(n);
    let out = eval_bsim4_batch(&cfg, &instances, &voltages);
    assert_eq!(out.len(), n);
}

#[test]
#[ignore = "exercises the optional GPU dispatch policy; run with --include-ignored"]
fn gpu_dispatch_force_on_allows_small_batches() {
    let n = 8;
    let cfg = NrConfig {
        use_gpu: Some(true),
        ..NrConfig::default()
    };
    assert!(should_use_gpu(&cfg, n));
    let (instances, voltages) = build_ladder(n);
    let out = eval_bsim4_batch(&cfg, &instances, &voltages);
    assert_eq!(out.len(), n);
}
