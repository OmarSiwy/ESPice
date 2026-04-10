//! Netlist compatibility tests (TESTING.md Section 3.5) — all ignored.

#[test]
#[ignore = "requires HSPICE netlist format extensions"]
fn compat_hspice_netlist_import() {}

#[test]
#[ignore = "requires Spectre netlist format parser"]
fn compat_spectre_netlist_import() {}

#[test]
#[ignore = "requires PSpice model card support"]
fn compat_pspice_model_import() {}

#[test]
#[ignore = "requires LTspice netlist format support"]
fn compat_ltspice_netlist_import() {}

#[test]
#[ignore = "requires SKY130 PDK model cards"]
fn compat_sky130_pdk_simulation() {}

#[test]
#[ignore = "requires IHP SG13G2 PDK model cards"]
fn compat_ihp_sg13g2_pdk_simulation() {}

#[test]
#[ignore = "requires GF180MCU PDK model cards"]
fn compat_gf180mcu_pdk_simulation() {}
