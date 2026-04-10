// SPDX-License-Identifier: LGPL-3.0-only
//
// OSDI ABI definitions follow the public OpenVAF OSDI spec; this file
// contains no OpenVAF source code.
//
// Integration tests for the `pisim-osdi` plugin loader.
//
// We exercise the loader along two axes:
//
// 1. Pure-Rust unit-style tests of the public API surface that do NOT
//    require a real `.osdi` shared object. These run unconditionally and
//    cover error paths, descriptor wrapping, trampoline buffer sizing,
//    and registry index hygiene.
//
// 2. A `#[ignore]`d test that builds a stub C shared object exporting
//    `OSDI_DESCRIPTORS` / `OSDI_NUM_DESCRIPTORS` / `OSDI_VERSION_*`, opens
//    it via [`OsdiPlugin::open`], and verifies the descriptor reads back
//    correctly. This test is `#[ignore]` by default because not every CI
//    environment ships with a working `cc` toolchain — run it locally
//    with `cargo test --package pisim-osdi -- --ignored` after `nix
//    develop` has provisioned a C compiler.

use core::ffi::c_void;
use core::ptr;
use std::path::PathBuf;

use pisim_core::ParamMap;
use pisim_osdi::{
    abi::{OsdiDescriptor, OSDI_VERSION_MAJOR, OSDI_VERSION_MINOR},
    OsdiError, OsdiPlugin, OsdiRegistry, OsdiTrampoline, SoaBuffers,
};

// ──────────────────────────────────────────────────────────────────────
//   Pure-Rust tests — always run
// ──────────────────────────────────────────────────────────────────────

fn make_empty_descriptor() -> OsdiDescriptor {
    OsdiDescriptor {
        name: ptr::null(),
        num_terminals: 4,
        num_nodes: 0,
        nodes: ptr::null(),
        num_collapsible: 0,
        collapsible: ptr::null(),
        num_jacobian_entries: 0,
        jacobian_entries: ptr::null(),
        num_react_entries: 0,
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
    }
}

#[test]
fn version_constants_match_loader() {
    assert_eq!(OSDI_VERSION_MAJOR, 0);
    assert!(OSDI_VERSION_MINOR >= 3);
}

#[test]
fn open_missing_file_returns_dlopen_error() {
    let err = OsdiPlugin::open(PathBuf::from("/nonexistent/__pisim_test__.osdi")).unwrap_err();
    assert!(matches!(err, OsdiError::DlOpen { .. }));
}

#[test]
fn registry_starts_empty() {
    let reg = OsdiRegistry::new();
    assert_eq!(reg.num_plugins(), 0);
    assert_eq!(reg.num_descriptors(), 0);
    assert_eq!(reg.num_instances(), 0);
}

#[test]
fn trampoline_sizes_buffers_from_descriptor() {
    let desc = make_empty_descriptor();
    let t = OsdiTrampoline::new(&desc);
    assert_eq!(t.buffers.voltages.len(), 4);
    assert_eq!(t.buffers.residual_resist.len(), 4);
    assert_eq!(t.buffers.jacobian_resist.len(), 0);
}

#[test]
fn trampoline_voltage_length_validation() {
    let desc = make_empty_descriptor();
    let mut t = OsdiTrampoline::new(&desc);
    // Wrong length → error.
    let err = t.write_voltages(&[1.0, 2.0], &desc).unwrap_err();
    assert!(matches!(
        err,
        OsdiError::VoltageLenMismatch { expected: 4, actual: 2, .. }
    ));
    // Correct length → ok.
    assert!(t.write_voltages(&[1.0, 2.0, 3.0, 4.0], &desc).is_ok());
}

#[test]
fn soa_buffers_clear_zeros_everything() {
    let desc = make_empty_descriptor();
    let mut buf = SoaBuffers::for_descriptor(&desc);
    buf.voltages.iter_mut().for_each(|v| *v = 9.0);
    buf.residual_resist.iter_mut().for_each(|v| *v = 9.0);
    buf.clear();
    assert!(buf.voltages.iter().all(|v| *v == 0.0));
    assert!(buf.residual_resist.iter().all(|v| *v == 0.0));
}

#[test]
fn registry_create_unknown_descriptor_errors() {
    let mut reg = OsdiRegistry::new();
    let err = reg
        .create_instance("not_real_model", &ParamMap::new(), 300.0)
        .unwrap_err();
    match err {
        OsdiError::MissingParameter { name, .. } => assert_eq!(name, "not_real_model"),
        other => panic!("expected MissingParameter, got {other:?}"),
    }
}

// ──────────────────────────────────────────────────────────────────────
//   Real-plugin test — requires `cc` and is `#[ignore]`d by default
// ──────────────────────────────────────────────────────────────────────

/// Build a minimal "stub OSDI" shared object using a system C compiler,
/// then open it through `OsdiPlugin::open` and verify the descriptor
/// table reads back correctly.
///
/// This is gated behind `#[ignore]` so the default `cargo test` run does
/// not depend on `cc`. CI / contributors should run:
///
/// ```bash
/// nix develop -c cargo test --package pisim-osdi -- --ignored
/// ```
///
/// to exercise this end-to-end path.
#[test]
#[ignore = "requires a system C compiler to build the stub .osdi"]
fn dlopen_stub_descriptor_round_trips() {
    use std::process::Command;

    let tmp = tempfile::tempdir().expect("tempdir");
    let src = tmp.path().join("stub.c");
    let lib = tmp.path().join("libstub_osdi.so");

    // The C source defines a single descriptor whose layout matches the
    // Rust `OsdiDescriptor`. We only populate the leading fields the
    // loader inspects (name, num_terminals, num_nodes, instance_size).
    std::fs::write(
        &src,
        r#"
#include <stdint.h>
#include <stddef.h>

const uint32_t OSDI_VERSION_MAJOR = 0;
const uint32_t OSDI_VERSION_MINOR = 3;
const uint32_t OSDI_NUM_DESCRIPTORS = 1;

/* Layout MUST mirror crates/osdi/src/abi.rs::OsdiDescriptor exactly. */
struct OsdiDescriptor {
    const char *name;
    uint32_t num_terminals;
    uint32_t num_nodes;
    const void *nodes;
    uint32_t num_collapsible;
    const void *collapsible;
    uint32_t num_jacobian_entries;
    const void *jacobian_entries;
    uint32_t num_react_entries;
    const void *react_entries;
    uint32_t instance_size;
    uint32_t model_size;
    uint32_t num_params;
    const void *params;
    uint32_t num_opvars;
    const void *opvars;
    void *setup_model;
    void *setup_instance;
    void *init_instance;
    void *eval;
    void *load_residual_resist;
    void *load_residual_react;
    void *load_jacobian_resist;
    void *load_jacobian_react;
    void *load_jacobian_contrib;
    void *load_noise;
    void *access;
};

static const char NAME[] = "stub_diode";

const struct OsdiDescriptor OSDI_DESCRIPTORS[1] = {
    {
        .name = NAME,
        .num_terminals = 2,
        .num_nodes = 0,
        .nodes = NULL,
        .num_collapsible = 0,
        .collapsible = NULL,
        .num_jacobian_entries = 0,
        .jacobian_entries = NULL,
        .num_react_entries = 0,
        .react_entries = NULL,
        .instance_size = 32,
        .model_size = 0,
        .num_params = 0,
        .params = NULL,
        .num_opvars = 0,
        .opvars = NULL,
        .setup_model = NULL,
        .setup_instance = NULL,
        .init_instance = NULL,
        .eval = NULL,
        .load_residual_resist = NULL,
        .load_residual_react = NULL,
        .load_jacobian_resist = NULL,
        .load_jacobian_react = NULL,
        .load_jacobian_contrib = NULL,
        .load_noise = NULL,
        .access = NULL,
    }
};
        "#,
    )
    .unwrap();

    let cc = std::env::var("CC").unwrap_or_else(|_| "cc".to_string());
    let status = Command::new(&cc)
        .args(["-shared", "-fPIC", "-o"])
        .arg(&lib)
        .arg(&src)
        .status()
        .expect("invoke cc");
    assert!(status.success(), "stub compile failed");

    let plugin = OsdiPlugin::open(&lib).expect("OsdiPlugin::open");
    assert_eq!(plugin.num_descriptors(), 1);
    assert_eq!(plugin.version(), (0, 3));

    let descriptor = plugin
        .find_descriptor("stub_diode")
        .expect("descriptor by name");
    assert_eq!(descriptor.num_terminals, 2);
    assert_eq!(descriptor.instance_size, 32);

    // Pointer-table sanity: every function field must read back as None
    // because the C side wrote NULL.
    assert!(descriptor.eval.is_none());
    assert!(descriptor.load_residual_resist.is_none());
    assert!(descriptor.load_jacobian_resist.is_none());

    // Registry round trip — load via the high-level API.
    let mut registry = OsdiRegistry::new();
    let names = registry.load_plugin(&lib).expect("registry load_plugin");
    assert_eq!(names, vec!["stub_diode"]);
    assert_eq!(registry.num_descriptors(), 1);
    assert!(registry.descriptor("stub_diode").is_some());
}

// Suppress an "unused" warning for the stub helper when the ignored test
// is not selected.
#[allow(dead_code)]
fn _force_link(_p: *mut c_void) {}
