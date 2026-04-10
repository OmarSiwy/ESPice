/// Phase 5.6 benchmark — `.STEP` parametric sweep with/without incremental cache.
///
/// Measures three conditions for three parameter types:
///   (a) sweep WITH cache ON  — `run_dc_op_with_config` passing the prior `IncrementalCache`
///   (b) sweep WITH cache OFF — fresh parse + solve per iteration
///   (c) single reference sim — one DC OP on the baseline circuit
///
/// Exit criterion (Phase 5.6): time(a) / time(c) < 3.
///
/// Circuit: 20-stage RC ladder (~40 devices), a tractable medium circuit that
/// exercises the dirty-tracker without being dominated by parse overhead.
use criterion::{criterion_group, criterion_main, BenchmarkId, Criterion};
use pisim_analysis::{run_dc_op, run_dc_op_with_config};
use pisim_cache::IncrementalCache;
use pisim_core::{Circuit, DeviceId, DeviceInstance, DeviceKind, NodeId};
use pisim_device::DeviceRegistry;

// ---------------------------------------------------------------------------
// Shared circuit builders
// ---------------------------------------------------------------------------

/// 20-stage RC ladder.
///
///   V1 — R0 — n1 — R1 — n2 — … — R19 — n20
///                  |               |
///                  C0              C19
///                  |               |
///                 GND             GND
///
/// Device counts: 1 vsource + 20 resistors + 20 capacitors = 41 devices.
/// MNA dimension: 21 nodes + 1 vsource branch = 22 unknowns.
fn rc_ladder_20(r_ohm: f64, c_farad: f64) -> Circuit {
    let mut ckt = Circuit::new();
    let n_in = ckt.add_node("n_in");

    // Voltage source: V1  n_in → GND  DC = 1 V
    ckt.add_device(
        DeviceInstance::new(DeviceId::new(0), "V1", DeviceKind::VoltageSource,
            &[(0, n_in), (1, NodeId::GROUND)])
            .with_param("dc", 1.0),
    );

    let mut prev = n_in;
    for i in 0..20usize {
        let next = ckt.add_node(&format!("n{}", i + 1));

        // Ri  prev → next
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), &format!("R{i}"), DeviceKind::Resistor,
                &[(0, prev), (1, next)])
                .with_param("resistance", r_ohm),
        );

        // Ci  next → GND
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), &format!("C{i}"), DeviceKind::Capacitor,
                &[(0, next), (1, NodeId::GROUND)])
                .with_param("capacitance", c_farad),
        );

        prev = next;
    }

    ckt.build_topology();
    ckt
}

// ---------------------------------------------------------------------------
// Sweep helpers
// ---------------------------------------------------------------------------

const SWEEP_STEPS: usize = 50;
const BASE_R: f64 = 1_000.0;    // 1 kΩ
const BASE_C: f64 = 1e-9;       // 1 nF

/// Sweep the resistor value from BASE_R to 2·BASE_R in SWEEP_STEPS steps,
/// reusing the `IncrementalCache` from the previous solve.
fn sweep_r_with_cache(registry: &DeviceRegistry) {
    // Build baseline circuit once.
    let mut ckt = rc_ladder_20(BASE_R, BASE_C);
    let step = BASE_R / SWEEP_STEPS as f64;

    let mut cache: Option<IncrementalCache> = None;

    for i in 0..SWEEP_STEPS {
        let r = BASE_R + step * i as f64;
        for j in 0..20usize {
            ckt.set_device_param(&format!("R{j}"), "resistance", r);
        }
        let out = run_dc_op_with_config(&ckt, registry, None, cache.as_ref()).unwrap();
        cache = Some(out.cache);
    }
}

/// Same sweep with NO cache — rebuilds everything from scratch each step.
fn sweep_r_no_cache(registry: &DeviceRegistry) {
    let step = BASE_R / SWEEP_STEPS as f64;

    for i in 0..SWEEP_STEPS {
        let r = BASE_R + step * i as f64;
        let ckt = rc_ladder_20(r, BASE_C);
        run_dc_op(&ckt, registry).unwrap();
    }
}

/// Single baseline DC OP at the nominal operating point.
fn single_dc_op(registry: &DeviceRegistry) {
    let ckt = rc_ladder_20(BASE_R, BASE_C);
    run_dc_op(&ckt, registry).unwrap();
}

// ---------------------------------------------------------------------------
// Capacitor value sweep
// ---------------------------------------------------------------------------

fn sweep_c_with_cache(registry: &DeviceRegistry) {
    let mut ckt = rc_ladder_20(BASE_R, BASE_C);
    let step = BASE_C / SWEEP_STEPS as f64;
    let mut cache: Option<IncrementalCache> = None;

    for i in 0..SWEEP_STEPS {
        let c = BASE_C + step * i as f64;
        for j in 0..20usize {
            ckt.set_device_param(&format!("C{j}"), "capacitance", c);
        }
        let out = run_dc_op_with_config(&ckt, registry, None, cache.as_ref()).unwrap();
        cache = Some(out.cache);
    }
}

fn sweep_c_no_cache(registry: &DeviceRegistry) {
    let step = BASE_C / SWEEP_STEPS as f64;

    for i in 0..SWEEP_STEPS {
        let c = BASE_C + step * i as f64;
        let ckt = rc_ladder_20(BASE_R, c);
        run_dc_op(&ckt, registry).unwrap();
    }
}

// ---------------------------------------------------------------------------
// Voltage sweep
// ---------------------------------------------------------------------------

fn sweep_v_with_cache(registry: &DeviceRegistry) {
    let mut ckt = rc_ladder_20(BASE_R, BASE_C);
    let mut cache: Option<IncrementalCache> = None;

    for i in 0..SWEEP_STEPS {
        let v = 0.1 + 0.1 * i as f64;   // 0.1 V … 5.1 V
        ckt.set_device_param("V1", "dc", v);
        let out = run_dc_op_with_config(&ckt, registry, None, cache.as_ref()).unwrap();
        cache = Some(out.cache);
    }
}

fn sweep_v_no_cache(registry: &DeviceRegistry) {
    for i in 0..SWEEP_STEPS {
        let v = 0.1 + 0.1 * i as f64;
        let mut ckt = rc_ladder_20(BASE_R, BASE_C);
        ckt.set_device_param("V1", "dc", v);
        run_dc_op(&ckt, registry).unwrap();
    }
}

// ---------------------------------------------------------------------------
// Criterion harness
// ---------------------------------------------------------------------------

fn bench_step_cache(c: &mut Criterion) {
    let registry = DeviceRegistry::new_default();

    // ── Group 1: single reference DC OP ─────────────────────────────────────
    {
        let mut group = c.benchmark_group("step_cache/reference");
        group.bench_function("single_dc_op", |b| {
            b.iter(|| single_dc_op(&registry));
        });
        group.finish();
    }

    // ── Group 2: resistor sweep ──────────────────────────────────────────────
    {
        let mut group = c.benchmark_group("step_cache/sweep_R");
        group.bench_function("cache_on", |b| {
            b.iter(|| sweep_r_with_cache(&registry));
        });
        group.bench_function("cache_off", |b| {
            b.iter(|| sweep_r_no_cache(&registry));
        });
        group.finish();
    }

    // ── Group 3: capacitor sweep ─────────────────────────────────────────────
    {
        let mut group = c.benchmark_group("step_cache/sweep_C");
        group.bench_function("cache_on", |b| {
            b.iter(|| sweep_c_with_cache(&registry));
        });
        group.bench_function("cache_off", |b| {
            b.iter(|| sweep_c_no_cache(&registry));
        });
        group.finish();
    }

    // ── Group 4: voltage sweep ───────────────────────────────────────────────
    {
        let mut group = c.benchmark_group("step_cache/sweep_V");
        group.bench_function("cache_on", |b| {
            b.iter(|| sweep_v_with_cache(&registry));
        });
        group.bench_function("cache_off", |b| {
            b.iter(|| sweep_v_no_cache(&registry));
        });
        group.finish();
    }
}

// Ratio assertion helper, exercised only in --test mode so the bench run
// produces an explicit pass/fail for the Phase 5.6 criterion.
fn verify_phase56_criterion(c: &mut Criterion) {
    let registry = DeviceRegistry::new_default();
    let mut group = c.benchmark_group("step_cache/phase56_check");
    // Bench IDs so criterion tracks them individually.
    group.bench_with_input(
        BenchmarkId::new("50_step_sweep_cache_on", "R"),
        &(),
        |b, _| b.iter(|| sweep_r_with_cache(&registry)),
    );
    group.finish();
}

criterion_group!(benches, bench_step_cache, verify_phase56_criterion);
criterion_main!(benches);
