//! OSDI end-to-end smoke tests — O.15.
//!
//! Tests that require an actual `.osdi` binary are marked `#[ignore]`.
//! Compile the binary first with:
//!   bash scripts/build_va_models.sh
//!
//! The remaining tests exercise the loader error paths, registry lifecycle,
//! trampoline buffer sizing, and parameter validation — all without any
//! external tools or compiled models.

use pisim_osdi::{OsdiError, OsdiPlugin, OsdiRegistry, OsdiTrampoline, SoaBuffers};

// ─── Loader error-path tests (no external tools needed) ──────────────────────

/// Attempting to open a non-existent path must return `OsdiError::DlOpen`.
#[test]
fn osdi_loader_smoke_missing_file() {
    let err = OsdiPlugin::open("/nonexistent/path/model_does_not_exist.osdi")
        .expect_err("expected error for missing file");
    match err {
        OsdiError::DlOpen { path, .. } => {
            assert!(
                path.contains("model_does_not_exist.osdi"),
                "path in error = {path}"
            );
        }
        other => panic!("expected DlOpen error, got {other:?}"),
    }
}

/// Loading a file that exists but is not a valid shared object must also
/// return a `DlOpen` error (the OS will reject it).
#[test]
fn osdi_loader_smoke_invalid_elf() {
    use std::io::Write;
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("garbage.osdi");
    {
        let mut f = std::fs::File::create(&path).expect("create");
        f.write_all(b"not an ELF binary").expect("write");
    }
    let err = OsdiPlugin::open(&path).expect_err("expected error for invalid ELF");
    assert!(
        matches!(err, OsdiError::DlOpen { .. }),
        "expected DlOpen, got {err:?}"
    );
}

// ─── Registry lifecycle tests (no external tools needed) ─────────────────────

/// A freshly-constructed registry is empty.
#[test]
fn osdi_registry_starts_empty() {
    let reg = OsdiRegistry::new();
    assert_eq!(reg.num_plugins(), 0);
    assert_eq!(reg.num_descriptors(), 0);
    assert_eq!(reg.num_instances(), 0);
    assert!(reg.descriptor("anything").is_none());
    assert!(reg.known_descriptors().is_empty());
}

/// Trying to load a non-existent plugin through the registry returns
/// `OsdiError::DlOpen`.
#[test]
fn osdi_registry_load_missing_plugin_errors() {
    let mut reg = OsdiRegistry::new();
    let err = reg
        .load_plugin("/nonexistent/path/missing.osdi")
        .expect_err("expected error");
    assert!(matches!(err, OsdiError::DlOpen { .. }), "got {err:?}");
}

/// `create_instance` on an unknown descriptor name returns
/// `OsdiError::MissingParameter`.
#[test]
fn osdi_registry_create_instance_unknown_name_errors() {
    let mut reg = OsdiRegistry::new();
    let params = pisim_core::ParamMap::new();
    let err = reg
        .create_instance("nonexistent_model", &params, 300.0)
        .expect_err("expected error");
    match err {
        OsdiError::MissingParameter { name, .. } => {
            assert_eq!(name, "nonexistent_model");
        }
        other => panic!("expected MissingParameter, got {other:?}"),
    }
}

/// `evaluate` with an out-of-bounds index returns
/// `OsdiError::InstanceOutOfBounds`.
#[test]
fn osdi_registry_evaluate_out_of_bounds_errors() {
    let mut reg = OsdiRegistry::new();
    let err = reg
        .evaluate(pisim_osdi::OsdiInstanceIdx::new(99), &[], 0.0, 0.0)
        .expect_err("expected OOB error");
    assert!(
        matches!(err, OsdiError::InstanceOutOfBounds(99)),
        "got {err:?}"
    );
}

/// `trampoline` with an out-of-bounds index returns
/// `OsdiError::InstanceOutOfBounds`.
#[test]
fn osdi_registry_trampoline_out_of_bounds_errors() {
    let reg = OsdiRegistry::new();
    let err = reg
        .trampoline(pisim_osdi::OsdiInstanceIdx::new(0))
        .expect_err("expected OOB error");
    assert!(
        matches!(err, OsdiError::InstanceOutOfBounds(0)),
        "got {err:?}"
    );
}

// ─── Trampoline / SoaBuffers unit tests (no external tools needed) ───────────

/// `SoaBuffers::clear` zeros all fields after they have been written to.
#[test]
fn osdi_soa_buffers_clear_zeroes_all_fields() {
    use std::ptr;
    use pisim_osdi::abi::OsdiDescriptor;

    let desc = OsdiDescriptor {
        name: ptr::null(),
        num_terminals: 3,
        num_nodes: 1,
        nodes: ptr::null(),
        num_collapsible: 0,
        collapsible: ptr::null(),
        num_jacobian_entries: 2,
        jacobian_entries: ptr::null(),
        num_react_entries: 1,
        react_entries: ptr::null(),
        instance_size: 64,
        model_size: 0,
        num_params: 0,
        params: ptr::null(),
        num_opvars: 0,
        opvars: ptr::null(),
        setup_model: None,
        setup_instance: None,
        init_instance: None,
        eval: None,
        load_residual_resist: None,
        load_residual_react: None,
        load_jacobian_resist: None,
        load_jacobian_react: None,
        load_jacobian_contrib: None,
        load_noise: None,
        access: None,
    };

    let mut buf = SoaBuffers::for_descriptor(&desc);

    // Write some non-zero values.
    buf.voltages[0] = 1.5;
    buf.residual_resist[0] = 2.5;
    buf.residual_react[0] = 3.5;
    buf.jacobian_resist[0] = 4.5;
    buf.jacobian_react[0] = 5.5;

    buf.clear();

    assert!(buf.voltages.iter().all(|&v| v == 0.0), "voltages not zeroed");
    assert!(
        buf.residual_resist.iter().all(|&v| v == 0.0),
        "residual_resist not zeroed"
    );
    assert!(
        buf.residual_react.iter().all(|&v| v == 0.0),
        "residual_react not zeroed"
    );
    assert!(
        buf.jacobian_resist.iter().all(|&v| v == 0.0),
        "jacobian_resist not zeroed"
    );
    assert!(
        buf.jacobian_react.iter().all(|&v| v == 0.0),
        "jacobian_react not zeroed"
    );
}

/// Buffer sizes derived from the descriptor are correct.
#[test]
fn osdi_soa_buffers_sizes_match_descriptor() {
    use std::ptr;
    use pisim_osdi::abi::OsdiDescriptor;

    let desc = OsdiDescriptor {
        name: ptr::null(),
        num_terminals: 4,     // e.g. BSIM4: D G S B
        num_nodes: 2,         // 2 internal nodes
        nodes: ptr::null(),
        num_collapsible: 0,
        collapsible: ptr::null(),
        num_jacobian_entries: 10,
        jacobian_entries: ptr::null(),
        num_react_entries: 6,
        react_entries: ptr::null(),
        instance_size: 256,
        model_size: 128,
        num_params: 0,
        params: ptr::null(),
        num_opvars: 0,
        opvars: ptr::null(),
        setup_model: None,
        setup_instance: None,
        init_instance: None,
        eval: None,
        load_residual_resist: None,
        load_residual_react: None,
        load_jacobian_resist: None,
        load_jacobian_react: None,
        load_jacobian_contrib: None,
        load_noise: None,
        access: None,
    };

    let buf = SoaBuffers::for_descriptor(&desc);

    // voltages: num_terminals only
    assert_eq!(buf.voltages.len(), 4);
    // residuals: num_terminals + num_nodes (total node count)
    assert_eq!(buf.residual_resist.len(), 6);
    assert_eq!(buf.residual_react.len(), 6);
    // jacobian: num_jacobian_entries / num_react_entries
    assert_eq!(buf.jacobian_resist.len(), 10);
    assert_eq!(buf.jacobian_react.len(), 6);
}

/// `write_voltages` validates slice length and fills the buffer correctly.
#[test]
fn osdi_trampoline_write_voltages_roundtrip() {
    use std::ptr;
    use pisim_osdi::abi::OsdiDescriptor;

    let desc = OsdiDescriptor {
        name: ptr::null(),
        num_terminals: 3,
        num_nodes: 0,
        nodes: ptr::null(),
        num_collapsible: 0,
        collapsible: ptr::null(),
        num_jacobian_entries: 0,
        jacobian_entries: ptr::null(),
        num_react_entries: 0,
        react_entries: ptr::null(),
        instance_size: 32,
        model_size: 0,
        num_params: 0,
        params: ptr::null(),
        num_opvars: 0,
        opvars: ptr::null(),
        setup_model: None,
        setup_instance: None,
        init_instance: None,
        eval: None,
        load_residual_resist: None,
        load_residual_react: None,
        load_jacobian_resist: None,
        load_jacobian_react: None,
        load_jacobian_contrib: None,
        load_noise: None,
        access: None,
    };

    let mut tramp = OsdiTrampoline::new(&desc);

    // Correct length — must succeed.
    tramp
        .write_voltages(&[1.0, -0.5, 2.3], &desc)
        .expect("write_voltages should succeed");
    assert_eq!(tramp.buffers.voltages, vec![1.0, -0.5, 2.3]);

    // Wrong length — must fail with VoltageLenMismatch.
    let err = tramp
        .write_voltages(&[1.0], &desc)
        .expect_err("expected length mismatch error");
    match err {
        OsdiError::VoltageLenMismatch { expected, actual, .. } => {
            assert_eq!(expected, 3);
            assert_eq!(actual, 1);
        }
        other => panic!("expected VoltageLenMismatch, got {other:?}"),
    }
}

/// `OsdiTrampoline::evaluate` with all-None function pointers completes
/// without error (all function calls are no-ops when the pointers are None).
#[test]
fn osdi_trampoline_evaluate_noop_descriptor_succeeds() {
    use std::ptr;
    use pisim_osdi::abi::OsdiDescriptor;
    use pisim_osdi::instance::synthetic_instance_for_tests;
    use std::sync::Arc;

    // We need a dummy Library handle. The only way to get one without a
    // real .so is to load a well-known system library. Skip on systems
    // where it's absent.
    let lib_path = if cfg!(target_os = "linux") {
        "/lib/x86_64-linux-gnu/libz.so.1"
    } else if cfg!(target_os = "macos") {
        "/usr/lib/libz.dylib"
    } else {
        return; // unsupported platform — skip
    };

    // libz is always present on Linux; if not found, skip gracefully.
    let library = match unsafe { libloading::Library::new(lib_path) } {
        Ok(lib) => Arc::new(lib),
        Err(_) => return, // library not found — skip
    };

    let desc = OsdiDescriptor {
        name: ptr::null(),
        num_terminals: 2,
        num_nodes: 0,
        nodes: ptr::null(),
        num_collapsible: 0,
        collapsible: ptr::null(),
        num_jacobian_entries: 1,
        jacobian_entries: ptr::null(),
        num_react_entries: 0,
        react_entries: ptr::null(),
        instance_size: 16,
        model_size: 0,
        num_params: 0,
        params: ptr::null(),
        num_opvars: 0,
        opvars: ptr::null(),
        setup_model: None,
        setup_instance: None,
        init_instance: None,
        eval: None,
        load_residual_resist: None,
        load_residual_react: None,
        load_jacobian_resist: None,
        load_jacobian_react: None,
        load_jacobian_contrib: None,
        load_noise: None,
        access: None,
    };

    let mut instance = synthetic_instance_for_tests(library, &desc);
    let mut tramp = OsdiTrampoline::new(&desc);

    tramp
        .write_voltages(&[1.0, 0.0], &desc)
        .expect("write_voltages");
    tramp
        .evaluate(&mut instance, 0.0, 1.0)
        .expect("evaluate with no-op descriptor");

    // All buffers still zero because no function pointers were invoked.
    assert!(tramp.buffers.residual_resist.iter().all(|&v| v == 0.0));
    assert!(tramp.buffers.jacobian_resist.iter().all(|&v| v == 0.0));
}

// ─── Full end-to-end tests (require openvaf + scripts/build_va_models.sh) ────

/// Full end-to-end: load a real BSIM4 OSDI binary and verify it exposes at
/// least one descriptor.  Requires `bash scripts/build_va_models.sh` to have
/// been run first.
#[test]
#[ignore = "requires openvaf + bash scripts/build_va_models.sh to produce models/osdi/bsim4.osdi"]
fn osdi_bsim4_golden_descriptor_count() {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../models/osdi/bsim4.osdi");
    let plugin = OsdiPlugin::open(path).expect("load bsim4.osdi");
    assert!(
        plugin.num_descriptors() >= 1,
        "expected at least 1 descriptor, got {}",
        plugin.num_descriptors()
    );
    let (major, minor) = plugin.version();
    println!("bsim4.osdi OSDI version {major}.{minor}, {} descriptors", plugin.num_descriptors());
}

/// Full end-to-end: load BSIM4, create an nmos instance, run one DC
/// evaluation, and verify the residual and Jacobian buffers are populated.
///
/// This is the primary regression guard: if OSDI loading, parameter
/// setting, or trampoline evaluation is broken, this test will catch it.
///
/// To run:
///   bash scripts/build_va_models.sh
///   cargo test osdi_bsim4_dc_evaluation -- --ignored
#[test]
#[ignore = "requires openvaf + bash scripts/build_va_models.sh to produce models/osdi/bsim4.osdi"]
fn osdi_bsim4_dc_evaluation() {
    use pisim_core::ParamMap;

    let osdi_path =
        concat!(env!("CARGO_MANIFEST_DIR"), "/../../models/osdi/bsim4.osdi");

    let mut registry = OsdiRegistry::new();
    let names = registry
        .load_plugin(osdi_path)
        .expect("load bsim4.osdi into registry");
    assert!(!names.is_empty(), "plugin must expose at least one descriptor");
    println!("registered descriptors: {names:?}");

    // Use the first registered descriptor name (typically "bsim4nmos" or similar).
    let model_name = &names[0];

    // Minimal BSIM4 NMOS parameter set for a DC bias point evaluation.
    let mut params = ParamMap::new();
    params.insert("tnom".to_string(), 27.0);   // nominal temperature (°C)
    params.insert("toxe".to_string(), 3.0e-9); // gate oxide thickness (m)
    params.insert("toxp".to_string(), 2.5e-9);
    params.insert("toxm".to_string(), 3.0e-9);
    params.insert("dtox".to_string(), 0.5e-9);
    params.insert("nch".to_string(), 2.4e17);  // channel doping
    params.insert("lmin".to_string(), 100e-9);
    params.insert("lmax".to_string(), 1.0e-6);
    params.insert("wmin".to_string(), 100e-9);
    params.insert("wmax".to_string(), 1.0e-6);
    params.insert("version".to_string(), 4.80);

    // Create instance at 300 K.
    let idx = registry
        .create_instance(model_name, &params, 300.0)
        .expect("create_instance");

    // BSIM4 NMOS: D G S B — 4 terminals.
    // Apply Vgs=1.0, Vds=0.5, Vbs=0.0, Vbd=0.0.
    let voltages = vec![0.5_f64, 1.0, 0.0, 0.0]; // D G S B

    let tramp = registry
        .evaluate(idx, &voltages, 0.0, 0.0)
        .expect("evaluate DC operating point");

    // After a valid evaluation the Jacobian must contain at least one
    // non-zero entry (the device is on at Vgs=1.0 V above threshold).
    let has_nonzero_jac = tramp
        .buffers
        .jacobian_resist
        .iter()
        .any(|&v| v.abs() > 0.0);
    assert!(
        has_nonzero_jac,
        "expected non-zero Jacobian entries for Vgs=1.0 V, got all-zero"
    );

    println!(
        "BSIM4 DC eval: {} Jacobian entries, first non-zero = {:.4e}",
        tramp.buffers.jacobian_resist.len(),
        tramp
            .buffers
            .jacobian_resist
            .iter()
            .find(|&&v| v.abs() > 0.0)
            .copied()
            .unwrap_or(0.0)
    );
}

/// Full end-to-end: load the simple diode model (faster to compile than
/// BSIM4), verify descriptor metadata, and run an evaluation.
///
/// To run:
///   bash scripts/build_va_models.sh
///   cargo test osdi_diode_dc_evaluation -- --ignored
#[test]
#[ignore = "requires openvaf + bash scripts/build_va_models.sh to produce models/osdi/diode.osdi"]
fn osdi_diode_dc_evaluation() {
    use pisim_core::ParamMap;

    let osdi_path =
        concat!(env!("CARGO_MANIFEST_DIR"), "/../../models/osdi/diode.osdi");

    let plugin = OsdiPlugin::open(osdi_path).expect("load diode.osdi");
    println!(
        "diode.osdi: version {}.{}, {} descriptor(s)",
        plugin.version().0,
        plugin.version().1,
        plugin.num_descriptors()
    );

    // Inspect named descriptors.
    for (name, _desc) in plugin.iter_named() {
        println!("  descriptor: {name}");
    }

    // Register and instantiate via registry.
    let mut registry = OsdiRegistry::new();
    let names = registry
        .load_plugin(osdi_path)
        .expect("load into registry");
    assert!(!names.is_empty());

    let model_name = &names[0];
    let mut params = ParamMap::new();
    params.insert("is".to_string(), 1e-14); // saturation current
    params.insert("n".to_string(), 1.0);    // ideality factor

    let idx = registry
        .create_instance(model_name, &params, 300.0)
        .expect("create diode instance");

    // Diode: anode, cathode — 2 terminals.
    // Forward bias at 0.7 V.
    let voltages = vec![0.7_f64, 0.0];

    let tramp = registry
        .evaluate(idx, &voltages, 0.0, 0.0)
        .expect("evaluate diode DC");

    // Residual (current) must be positive under forward bias.
    let has_current = tramp.buffers.residual_resist.iter().any(|&v| v > 0.0);
    assert!(
        has_current,
        "expected positive residual under forward bias, got {:?}",
        tramp.buffers.residual_resist
    );

    println!(
        "Diode DC: residual={:.4e}, Jacobian={:.4e}",
        tramp.buffers.residual_resist[0],
        tramp.buffers.jacobian_resist.first().copied().unwrap_or(0.0)
    );
}
