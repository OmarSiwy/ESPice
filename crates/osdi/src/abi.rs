// SPDX-License-Identifier: LGPL-3.0-only
//
// OSDI ABI definitions follow the public OpenVAF OSDI spec; this file
// contains no OpenVAF source code.
//
// Source spec: https://openvaf.semimod.de/docs/osdi/

//! # Raw OSDI C ABI
//!
//! Direct `#[repr(C)]` bindings to the OSDI 0.3 ABI as documented in the
//! public OpenVAF OSDI specification. Field order, layout, and pointer
//! signatures here MUST match the OpenVAF emitter byte-for-byte — anything
//! that diverges will silently corrupt memory at the trampoline boundary.
//!
//! All structs in this module are `#[repr(C)]`. None of them implement
//! `Drop` because they are owned and freed by the plugin shared object
//! itself, not by Rust.
//!
//! ## Type conventions
//!
//! - C `bool` (1 byte): we use [`OsdiBool`] (`u8`).
//! - C `double`: `f64`.
//! - C `int`/`uint32_t`: `i32`/`u32`.
//! - C `void *`: `*mut core::ffi::c_void`.
//! - C strings (`const char *`): `*const c_char` (UTF-8, NUL-terminated).
//! - Function pointers: `Option<unsafe extern "C" fn(...)>` so a `0x0`
//!   slot decodes as `None` (matches the C ABI layout exactly).

use core::ffi::{c_char, c_void};

/// OSDI major version we speak (matches OpenVAF 0.x). Bump when the layout
/// of any of the structs in this file changes.
pub const OSDI_VERSION_MAJOR: u32 = 0;

/// OSDI minor version we speak. Bump on additive changes.
pub const OSDI_VERSION_MINOR: u32 = 3;

/// Symbol name exported by every OSDI shared object listing the device
/// descriptors it provides. The symbol is a `*const OsdiDescriptor` array
/// of length [`OSDI_NUM_DESCRIPTORS_SYMBOL`].
pub const OSDI_DESCRIPTORS_SYMBOL: &[u8] = b"OSDI_DESCRIPTORS\0";

/// Symbol exporting the number of descriptors as a `u32`.
pub const OSDI_NUM_DESCRIPTORS_SYMBOL: &[u8] = b"OSDI_NUM_DESCRIPTORS\0";

/// Symbol exporting the OSDI ABI major version as a `u32`.
pub const OSDI_VERSION_MAJOR_SYMBOL: &[u8] = b"OSDI_VERSION_MAJOR\0";

/// Symbol exporting the OSDI ABI minor version as a `u32`.
pub const OSDI_VERSION_MINOR_SYMBOL: &[u8] = b"OSDI_VERSION_MINOR\0";

/// 1-byte boolean matching the platform C ABI.
pub type OsdiBool = u8;

/// A pair of node indices (e.g., terminal mapping for a Jacobian entry).
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct OsdiNodePair {
    pub node_1: u32,
    pub node_2: u32,
}

/// Per-node metadata for an OSDI descriptor.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct OsdiNode {
    /// NUL-terminated UTF-8 node name (e.g. `"D"`, `"G"`, `"S"`, `"B"`).
    pub name: *const c_char,
    /// Bit field flags (internal node, residual flag, …).
    pub units: *const c_char,
    /// Residual units identifier (`OSDI_UNIT_*` constant in the spec).
    pub residual_units: u32,
    /// Whether this node is electrical (vs. thermal/internal).
    pub is_flow: OsdiBool,
}

/// Describes a single parameter or operating-point variable exposed by the
/// device model.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct OsdiParamOpvar {
    /// All names this parameter can be referenced by (aliases).
    pub num_alias: u32,
    pub alias: *const *const c_char,
    /// Canonical parameter name (NUL-terminated UTF-8).
    pub name: *const c_char,
    /// Human-readable description.
    pub description: *const c_char,
    /// Units string ("V", "F", …).
    pub units: *const c_char,
    /// Type tag — see `OSDI_PARAM_TYPE_*` constants.
    pub flags: u32,
    /// Byte offset of the slot inside the per-instance buffer.
    pub offset: u32,
}

/// Simulator-supplied scalar parameters (temperature, vt, …).
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct OsdiSimParas {
    /// NUL-terminated names array.
    pub names: *mut *mut c_char,
    /// Parallel f64 values array. `vals[i]` corresponds to `names[i]`.
    pub vals: *mut f64,
    /// String-valued parameters: names array.
    pub names_str: *mut *mut c_char,
    /// String-valued parameters: values array.
    pub vals_str: *mut *mut c_char,
}

/// Per-evaluation context: time, frequency, and pointers to the analysis
/// state buffers the plugin reads from / writes to.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct OsdiSimInfo {
    /// Pointer to simulator-supplied global parameters.
    pub paras: OsdiSimParas,
    /// Absolute simulation time in seconds.
    pub abstime: f64,
    /// Per-node previous-step solution (for transient state).
    pub prev_solve: *mut f64,
    /// Optional state pointer for state-bearing devices.
    pub prev_state: *mut f64,
    /// Optional next-state pointer.
    pub next_state: *mut f64,
    /// Bit-encoded flags describing analysis kind (DC, TRAN, AC, NOISE, …)
    pub flags: u32,
}

/// Returned by `init_instance` describing per-instance node fan-out and
/// any required matrix-stamping pairs.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct OsdiInitInfo {
    /// Combined flags / status code; non-zero in any error bit means abort.
    pub flags: u32,
    /// Number of error/warning records.
    pub num_errors: u32,
    /// Pointer to error records (NUL-terminated strings inside the plugin).
    pub errors: *mut OsdiInitError,
}

/// One error/warning record produced by `init_instance`.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct OsdiInitError {
    pub code: u32,
    pub payload: OsdiInitErrorPayload,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub union OsdiInitErrorPayload {
    pub parameter_id: u32,
    pub message: *const c_char,
}

impl core::fmt::Debug for OsdiInitErrorPayload {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.write_str("OsdiInitErrorPayload(<union>)")
    }
}

// ─── Function pointer aliases ─────────────────────────────────────────────

/// `init_instance(handle, sim_info, temperature) -> OsdiInitInfo`
pub type OsdiInitInstanceFn = unsafe extern "C" fn(
    instance: *mut c_void,
    sim_info: *mut OsdiSimInfo,
    temperature: f64,
) -> OsdiInitInfo;

/// `setup_model(handle, sim_info)`: bake model-card parameters.
pub type OsdiSetupModelFn =
    unsafe extern "C" fn(handle: *mut c_void, sim_info: *mut OsdiSimInfo) -> OsdiInitInfo;

/// `setup_instance(handle, model, sim_info)`: bake per-instance parameters.
pub type OsdiSetupInstanceFn = unsafe extern "C" fn(
    handle: *mut c_void,
    model: *mut c_void,
    sim_info: *mut OsdiSimInfo,
) -> OsdiInitInfo;

/// `eval(handle, sim_info)`: compute residual + Jacobian for the current x.
pub type OsdiEvalFn =
    unsafe extern "C" fn(handle: *mut c_void, sim_info: *mut OsdiSimInfo) -> u32;

/// `load_residual_resist(handle, dst)`: write resistive residual into `dst`.
pub type OsdiLoadResidualFn = unsafe extern "C" fn(handle: *mut c_void, dst: *mut f64);

/// `load_residual_react(handle, dst)`: write reactive residual.
pub type OsdiLoadResidualReactFn = unsafe extern "C" fn(handle: *mut c_void, dst: *mut f64);

/// `load_jacobian_resist(handle, dst)`: write conductance Jacobian.
pub type OsdiLoadJacobianFn = unsafe extern "C" fn(handle: *mut c_void, dst: *mut f64);

/// `load_jacobian_react(handle, dst, alpha)`: write reactive Jacobian
/// scaled by integration alpha.
pub type OsdiLoadJacobianReactFn =
    unsafe extern "C" fn(handle: *mut c_void, dst: *mut f64, alpha: f64);

/// `load_noise(handle, freq, dst)`: write noise contributions at `freq`.
pub type OsdiLoadNoiseFn =
    unsafe extern "C" fn(handle: *mut c_void, freq: f64, dst: *mut f64);

/// `load_jacobian_contrib(handle, dst)`: contributions Jacobian (Verilog-A
/// `<+` operator). Optional.
pub type OsdiLoadJacobianContribFn = unsafe extern "C" fn(handle: *mut c_void, dst: *mut f64);

/// `access(handle, name, vt)`: parameter getter/setter helper. Optional.
pub type OsdiAccessFn = unsafe extern "C" fn(
    handle: *mut c_void,
    name: *const c_char,
    val: *mut f64,
    write: OsdiBool,
) -> u32;

// ─── The descriptor ───────────────────────────────────────────────────────

/// `OsdiDescriptor` — top-level table exported by every OSDI plugin.
///
/// One descriptor per device kind (e.g. `bsim4nmos`, `diode`, `bjt_npn`).
/// Layout MUST match OpenVAF's emitted struct exactly. The pointers below
/// are owned by the plugin shared object; we never free them.
#[repr(C)]
pub struct OsdiDescriptor {
    /// Canonical model name (`"bsim4nmos"`, …). NUL-terminated UTF-8.
    pub name: *const c_char,
    /// Number of external (electrical) terminals.
    pub num_terminals: u32,
    /// Number of internal nodes (Verilog-A `internal node` declarations).
    pub num_nodes: u32,
    /// Pointer to `[OsdiNode; num_nodes]`.
    pub nodes: *const OsdiNode,
    /// Number of `node_pairs` entries (collapses).
    pub num_collapsible: u32,
    /// Pointer to `[OsdiNodePair; num_collapsible]`.
    pub collapsible: *const OsdiNodePair,
    /// Number of Jacobian-resist entries.
    pub num_jacobian_entries: u32,
    /// Pointer to `[OsdiNodePair; num_jacobian_entries]`.
    pub jacobian_entries: *const OsdiNodePair,
    /// Number of reactive Jacobian entries.
    pub num_react_entries: u32,
    /// Pointer to `[OsdiNodePair; num_react_entries]`.
    pub react_entries: *const OsdiNodePair,
    /// Per-instance buffer size (bytes). Caller allocates `instance_size`
    /// bytes of zeroed memory and passes the pointer to all functions
    /// below as the `handle`.
    pub instance_size: u32,
    /// Per-model buffer size (bytes). Some models share state across
    /// instances (e.g. BSIM4 model card).
    pub model_size: u32,
    /// Number of parameters declared (`parameter` blocks in Verilog-A).
    pub num_params: u32,
    /// Pointer to `[OsdiParamOpvar; num_params]`.
    pub params: *const OsdiParamOpvar,
    /// Number of operating-point output variables.
    pub num_opvars: u32,
    /// Pointer to `[OsdiParamOpvar; num_opvars]`.
    pub opvars: *const OsdiParamOpvar,

    // ── Function table ──────────────────────────────────────────────────
    /// Bake model-card parameters.
    pub setup_model: Option<OsdiSetupModelFn>,
    /// Bake per-instance parameters.
    pub setup_instance: Option<OsdiSetupInstanceFn>,
    /// One-time `init_instance` called after `setup_instance`.
    pub init_instance: Option<OsdiInitInstanceFn>,
    /// Compute g(x), q(x) given the current solution. Called every NR iter.
    pub eval: Option<OsdiEvalFn>,
    /// Read out resistive residual.
    pub load_residual_resist: Option<OsdiLoadResidualFn>,
    /// Read out reactive residual.
    pub load_residual_react: Option<OsdiLoadResidualReactFn>,
    /// Read out resistive Jacobian.
    pub load_jacobian_resist: Option<OsdiLoadJacobianFn>,
    /// Read out reactive Jacobian (multiplied by integration alpha).
    pub load_jacobian_react: Option<OsdiLoadJacobianReactFn>,
    /// Read out Verilog-A `<+` contributions Jacobian (optional).
    pub load_jacobian_contrib: Option<OsdiLoadJacobianContribFn>,
    /// Read out noise current density at a given frequency.
    pub load_noise: Option<OsdiLoadNoiseFn>,
    /// Optional access helper for parameter / opvar GET/SET.
    pub access: Option<OsdiAccessFn>,
}

// SAFETY: `OsdiDescriptor` itself is just plain old data + function
// pointers; the underlying plugin shared object guarantees its descriptors
// are statically allocated and immutable for the lifetime of the dlopen
// handle. Sending the descriptor *between* threads (e.g. behind an `Arc`)
// is therefore sound; concurrent access is mediated by `OsdiInstance`'s
// `&mut self` discipline.
unsafe impl Send for OsdiDescriptor {}
unsafe impl Sync for OsdiDescriptor {}

#[cfg(test)]
mod tests {
    use super::*;
    use core::mem::{align_of, size_of};

    #[test]
    fn node_pair_layout() {
        assert_eq!(size_of::<OsdiNodePair>(), 8);
        assert_eq!(align_of::<OsdiNodePair>(), 4);
    }

    #[test]
    fn descriptor_is_pointer_table() {
        // Sanity: every field is at least pointer-aligned.
        assert!(align_of::<OsdiDescriptor>() >= align_of::<*const c_void>());
    }

    #[test]
    fn version_constants_are_sane() {
        assert!(OSDI_VERSION_MAJOR == 0);
        assert!(OSDI_VERSION_MINOR >= 3);
    }

    #[test]
    fn function_pointer_options_are_pointer_sized() {
        // `Option<unsafe extern "C" fn(...)>` MUST be the same size as a
        // raw function pointer for the C ABI to round-trip safely.
        assert_eq!(
            size_of::<Option<OsdiInitInstanceFn>>(),
            size_of::<*const c_void>(),
        );
        assert_eq!(
            size_of::<Option<OsdiLoadResidualFn>>(),
            size_of::<*const c_void>(),
        );
    }
}
