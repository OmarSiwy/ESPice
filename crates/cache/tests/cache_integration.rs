//! Phase 5 cache integration tests.
//!
//! Verifies the four contracts the prompt called out:
//!
//! 1. Topology hash stable across parameter changes (only structure matters).
//! 2. Dirty tracking propagates through node adjacency.
//! 3. Compiled-eval round-trip on a simple resistor (analytic linearisation).
//! 4. Woodbury rank-1 update vs full refactor agree within 1e-12.

use bigospice_cache::{
    CacheManager, CompiledEvalCache, DeviceIdx, DirtyTracker, ParamChange, SymbolicLu,
    TopologyHash, WoodburyUpdate,
};
use bigospice_core::{Circuit, DeviceId, DeviceInstance, DeviceKind, NodeId};

/// Build: V1=5V from node 1 to GND, R1=1k from node 1 to node 2, R2=1k from node 2 to GND.
fn voltage_divider(r1: f64, r2: f64) -> Circuit {
    let mut ckt = Circuit::new();
    let n1 = ckt.add_node("1");
    let n2 = ckt.add_node("2");

    let v1 = DeviceInstance::new(
        DeviceId::new(0),
        "V1",
        DeviceKind::VoltageSource,
        &[(0, n1), (1, NodeId::GROUND)],
    )
    .with_param("dc", 5.0);
    let r1d = DeviceInstance::new(
        DeviceId::new(0),
        "R1",
        DeviceKind::Resistor,
        &[(0, n1), (1, n2)],
    )
    .with_param("resistance", r1);
    let r2d = DeviceInstance::new(
        DeviceId::new(0),
        "R2",
        DeviceKind::Resistor,
        &[(0, n2), (1, NodeId::GROUND)],
    )
    .with_param("resistance", r2);

    ckt.add_device(v1);
    ckt.add_device(r1d);
    ckt.add_device(r2d);
    ckt.build_topology();
    ckt
}

#[test]
fn topology_hash_stable_across_parameter_changes() {
    let ckt_a = voltage_divider(1_000.0, 1_000.0);
    let ckt_b = voltage_divider(2_200.0, 4_700.0);
    let ckt_c = voltage_divider(1.0, 1.0e9);

    let h_a = TopologyHash::from_circuit(&ckt_a);
    let h_b = TopologyHash::from_circuit(&ckt_b);
    let h_c = TopologyHash::from_circuit(&ckt_c);

    assert_eq!(h_a, h_b, "param-only change must not move topology hash");
    assert_eq!(h_a, h_c, "param-only change must not move topology hash");
}

#[test]
fn topology_hash_changes_when_topology_does() {
    let ckt = voltage_divider(1_000.0, 1_000.0);
    let h_orig = TopologyHash::from_circuit(&ckt);

    // Different structure: extra node + extra resistor.
    let mut ckt2 = Circuit::new();
    let n1 = ckt2.add_node("1");
    let n2 = ckt2.add_node("2");
    let n3 = ckt2.add_node("3");
    ckt2.add_device(
        DeviceInstance::new(
            DeviceId::new(0),
            "V1",
            DeviceKind::VoltageSource,
            &[(0, n1), (1, NodeId::GROUND)],
        )
        .with_param("dc", 5.0),
    );
    ckt2.add_device(
        DeviceInstance::new(
            DeviceId::new(0),
            "R1",
            DeviceKind::Resistor,
            &[(0, n1), (1, n2)],
        )
        .with_param("resistance", 1.0),
    );
    ckt2.add_device(
        DeviceInstance::new(
            DeviceId::new(0),
            "R2",
            DeviceKind::Resistor,
            &[(0, n2), (1, n3)],
        )
        .with_param("resistance", 1.0),
    );
    ckt2.add_device(
        DeviceInstance::new(
            DeviceId::new(0),
            "R3",
            DeviceKind::Resistor,
            &[(0, n3), (1, NodeId::GROUND)],
        )
        .with_param("resistance", 1.0),
    );
    ckt2.build_topology();
    let h2 = TopologyHash::from_circuit(&ckt2);
    assert_ne!(h_orig, h2);
}

#[test]
fn dirty_tracker_propagates_through_node_adjacency() {
    let ckt = voltage_divider(1_000.0, 1_000.0);
    let mut tracker = DirtyTracker::new(ckt.devices().len(), ckt.nodes().len());
    tracker.rebuild_adjacency(&ckt);

    // R1 is device index 1; it touches nodes 1 and 2.
    tracker.mark_device(DeviceId::new(1));
    assert!(tracker.is_dirty(DeviceId::new(1)));

    // After propagation, V1 (touches node 1) and R2 (touches node 2) should also be dirty.
    tracker.propagate();
    assert!(
        tracker.is_dirty(DeviceId::new(0)),
        "V1 shares node 1 with R1"
    );
    assert!(
        tracker.is_dirty(DeviceId::new(2)),
        "R2 shares node 2 with R1"
    );
    assert_eq!(tracker.dirty_device_count(), 3);
}

#[test]
fn compiled_eval_round_trip_resistor() {
    // Resistor I = V/R between two nodes; affine model is exact.
    let r = 1_000.0;
    let g_val = 1.0 / r;
    let g_block = [g_val, -g_val, -g_val, g_val];
    let mut cache = CompiledEvalCache::new(1);
    cache.tolerance = 100.0; // resistor is linear; arbitrary excursions ok
    cache.store(DeviceIdx(0), 2, &[0.0, 0.0], &g_block, &[0.0, 0.0]);

    // Replay at several voltages.
    let cases = [(1.0, 0.0), (2.5, 1.5), (-0.3, 0.2)];
    for (v_a, v_b) in cases {
        let mut out = [0.0, 0.0];
        cache.replay(DeviceIdx(0), &[v_a, v_b], &mut out).unwrap();
        let expected_a = (v_a - v_b) * g_val;
        let expected_b = -(v_a - v_b) * g_val;
        assert!((out[0] - expected_a).abs() < 1e-12);
        assert!((out[1] - expected_b).abs() < 1e-12);
    }
    assert_eq!(cache.hits, cases.len() as u64);
}

#[test]
fn compiled_eval_diode_linearization_local() {
    // Linearise a diode I = Is*(exp(V/Vt) - 1) at V0=0.7 V.
    let is: f64 = 1e-14;
    let vt: f64 = 0.025_852;
    let v0: f64 = 0.7;
    let i0: f64 = is * ((v0 / vt).exp() - 1.0);
    let g0: f64 = (is / vt) * (v0 / vt).exp();

    // 1×1 affine model.
    let mut cache = CompiledEvalCache::new(1);
    cache.tolerance = 0.01; // 10 mV.
    cache.store(DeviceIdx(0), 1, &[i0], &[g0], &[v0]);

    // Replay at V = 0.705 (within tolerance) — should match a Taylor expansion.
    let mut out = [0.0];
    cache
        .replay(DeviceIdx(0), &[0.705], &mut out)
        .expect("within tolerance");
    let expected = i0 + g0 * (0.705 - v0);
    assert!((out[0] - expected).abs() < 1e-15);

    // Replay at V = 1.0 — out of tolerance, should miss.
    assert!(cache.replay(DeviceIdx(0), &[1.0], &mut out).is_none());
    assert!(!cache.is_valid(DeviceIdx(0)));
}

#[test]
fn woodbury_rank1_matches_full_refactor() {
    // J_old, then add a rank-1 update; reference solution uses the explicit
    // J_new inverse.  Both must agree to 1e-12.
    let j_old = [
        4.0_f64, 1.0, 0.0,
        1.0, 3.0, 1.0,
        0.0, 1.0, 2.0,
    ];
    let u = [0.5, 0.7, 0.0];
    let v = [0.0, 0.6, 0.4];
    let mut j_new = j_old;
    for i in 0..3 {
        for j in 0..3 {
            j_new[i * 3 + j] += u[i] * v[j];
        }
    }
    let b = [1.0, 2.0, 3.0];

    fn solve3(a: &[f64], b: &[f64], out: &mut [f64]) {
        let det = a[0] * (a[4] * a[8] - a[5] * a[7])
            - a[1] * (a[3] * a[8] - a[5] * a[6])
            + a[2] * (a[3] * a[7] - a[4] * a[6]);
        let inv = [
            (a[4] * a[8] - a[5] * a[7]) / det,
            -(a[1] * a[8] - a[2] * a[7]) / det,
            (a[1] * a[5] - a[2] * a[4]) / det,
            -(a[3] * a[8] - a[5] * a[6]) / det,
            (a[0] * a[8] - a[2] * a[6]) / det,
            -(a[0] * a[5] - a[2] * a[3]) / det,
            (a[3] * a[7] - a[4] * a[6]) / det,
            -(a[0] * a[7] - a[1] * a[6]) / det,
            (a[0] * a[4] - a[1] * a[3]) / det,
        ];
        for r in 0..3 {
            let mut s = 0.0;
            for c in 0..3 {
                s += inv[r * 3 + c] * b[c];
            }
            out[r] = s;
        }
    }

    let mut x_ref = [0.0; 3];
    solve3(&j_new, &b, &mut x_ref);

    let mut wood = WoodburyUpdate::new(3);
    wood.push_rank1(&u, &v);
    let mut x_wood = [0.0; 3];
    wood.solve(&b, &mut x_wood, |rhs, out| solve3(&j_old, rhs, out))
        .unwrap();

    let mut max_err = 0.0_f64;
    for i in 0..3 {
        let e = (x_ref[i] - x_wood[i]).abs();
        if e > max_err {
            max_err = e;
        }
    }
    assert!(max_err < 1e-12, "max err = {max_err}");
}

#[test]
fn cache_manager_full_lifecycle() {
    let ckt = voltage_divider(1_000.0, 1_000.0);
    let mut mgr = CacheManager::new();

    // First build → miss, must build symbolic.
    assert!(!mgr.on_topology_built(&ckt));
    mgr.store_symbolic(SymbolicLu::empty(ckt.mna_dimension()));
    assert!(mgr.cached_symbolic().is_some());

    // Solve completes — warm start now valid.
    mgr.on_solve_complete(&[5.0, 2.5, -0.0025]);
    assert_eq!(mgr.warm_start().unwrap(), &[5.0, 2.5, -0.0025]);

    // Param sweep on R2 — same topology, must hit.
    let ckt2 = voltage_divider(1_000.0, 2_000.0);
    assert!(mgr.on_topology_built(&ckt2));
    assert_eq!(mgr.topology_hits, 1);

    // Mark a device dirty via the param-change API.
    mgr.on_param_changed(DeviceId::new(2), ParamChange::Scaling { factor: 2.0 });
    assert!(mgr.dirty.is_dirty(DeviceId::new(2)));
}

#[test]
fn checkpoint_arena_nearest_before() {
    use bigospice_cache::TransientArena;

    let mut arena = TransientArena::new();
    arena.push(0.0, &[0.0, 0.0], &[], &[]);
    arena.push(1e-6, &[0.1, 0.2], &[], &[]);
    arena.push(5e-6, &[0.5, 0.6], &[], &[]);
    arena.push(1e-5, &[1.0, 1.1], &[], &[]);

    let idx = arena.nearest_before(7e-6).unwrap();
    let cp = arena.get(idx).unwrap();
    assert_eq!(cp.time, 5e-6);
    assert_eq!(cp.state, &[0.5, 0.6]);
}
