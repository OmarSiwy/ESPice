// SPDX-License-Identifier: LGPL-3.0-only
//
// OSDI ABI definitions follow the public OpenVAF OSDI spec; this file
// contains no OpenVAF source code. BigOSpice consumes the *output* of OpenVAF
// (compiled `.osdi` shared objects) via `dlopen`. The OSDI ABI itself is
// not GPL — only the OpenVAF compiler is. We never link OpenVAF.
//
// Reference: https://openvaf.semimod.de/docs/osdi/

//! # BigOSpice OSDI Plugin Loader
//!
//! This crate loads compiled Verilog-A models produced by OpenVAF (`.osdi`
//! shared objects) at runtime via `dlopen`/`libloading`, exposes their
//! `OsdiDescriptor` table, instantiates devices, and bridges them into
//! BigOSpice's stamping layer.
//!
//! ## Architecture
//!
//! ```text
//! ┌──────────────┐    dlopen     ┌──────────────────┐
//! │  incspice CLI   │──────────────▶│  bsim4.osdi (.so)│
//! └──────┬───────┘   libloading  └────────┬─────────┘
//!        │                                 │
//!        │ register descriptor             │ OsdiDescriptor
//!        ▼                                 ▼
//! ┌───────────────────┐            ┌───────────────────┐
//! │ OsdiRegistry      │◀───────────│ OsdiPlugin        │
//! │ (descriptor map)  │            │ (Library handle)  │
//! └────────┬──────────┘            └───────────────────┘
//!          │
//!          ▼
//! ┌────────────────────┐  voltages   ┌──────────────────┐
//! │ DeviceKind::Osdi   │────────────▶│ OsdiTrampoline   │
//! │  (dispatch shim)   │◀────────────│ (load + Jacobian)│
//! └────────────────────┘  conduct.   └──────────────────┘
//! ```
//!
//! ## User workflow
//!
//! ```bash
//! # 1. Compile the Verilog-A model with OpenVAF (separate, GPL-3 tool)
//! openvaf bsim4.va -o bsim4.osdi
//!
//! # 2. Load it into BigOSpice at runtime
//! incspice --osdi bsim4.osdi circuit.sp
//! ```
//!
//! ## Memory model (DOD)
//!
//! Per-OSDI-device-kind we keep one `OsdiPlugin` (the loaded library and
//! descriptor pointer) plus a [`SoaBuffers`] struct of contiguous
//! `Vec<f64>` columns for terminal voltages and conductance/residual
//! outputs. All plugin invocations operate on tightly packed slices so
//! the trampoline never touches the heap on the hot path.
//!
//! [`SoaBuffers`]: trampoline::SoaBuffers

pub(crate) mod abi;
pub(crate) mod device_kind;
pub(crate) mod instance;
pub(crate) mod loader;
pub(crate) mod registry;
pub(crate) mod trampoline;

pub use abi::{
    OSDI_VERSION_MAJOR, OSDI_VERSION_MINOR, OsdiDescriptor, OsdiInitInfo, OsdiNodePair,
    OsdiParamOpvar, OsdiSimInfo, OsdiSimParas,
};
pub use device_kind::{OsdiDeviceKind, OsdiInstanceIdx};
pub use instance::{OsdiHbEval, OsdiInstance};
pub use loader::OsdiPlugin;
pub use registry::OsdiRegistry;
pub use trampoline::{OsdiTrampoline, SoaBuffers};

use thiserror::Error;

/// Errors raised by the OSDI loader / trampoline.
#[derive(Debug, Error)]
pub enum OsdiError {
    /// `dlopen` failed (file not found, missing symbol, invalid ELF, etc.)
    #[error("failed to open OSDI plugin {path}: {source}")]
    DlOpen {
        path: String,
        #[source]
        source: libloading::Error,
    },

    /// The plugin did not export the expected `OSDI_DESCRIPTORS` symbol.
    #[error("OSDI plugin {path} missing symbol `{symbol}`: {source}")]
    MissingSymbol {
        path: String,
        symbol: &'static str,
        #[source]
        source: libloading::Error,
    },

    /// Plugin reported an OSDI ABI version we cannot speak.
    #[error(
        "OSDI plugin {path}: unsupported version {found_major}.{found_minor} \
         (this loader supports {expected_major}.{expected_minor})"
    )]
    VersionMismatch {
        path: String,
        found_major: u32,
        found_minor: u32,
        expected_major: u32,
        expected_minor: u32,
    },

    /// init_instance returned a non-zero error flag.
    #[error("OSDI init_instance failed for `{name}`: flags=0x{flags:08x}")]
    InitFailed { name: String, flags: u32 },

    /// Tried to invoke a function pointer that was null in the descriptor.
    #[error("OSDI descriptor `{name}` has null function pointer `{field}`")]
    NullFunctionPointer {
        name: &'static str,
        field: &'static str,
    },

    /// Required parameter not present in `ParamMap`.
    #[error("OSDI device `{name}` missing required parameter `{param}`")]
    MissingParameter { name: String, param: String },

    /// Caller asked for an instance index that does not exist.
    #[error("OSDI instance index {0} out of bounds")]
    InstanceOutOfBounds(usize),

    /// Caller passed a voltage slice of the wrong length for the descriptor.
    #[error("OSDI device `{name}` expected {expected} terminal voltages, got {actual}")]
    VoltageLenMismatch {
        name: String,
        expected: usize,
        actual: usize,
    },
}

/// Convenience alias.
pub type OsdiResult<T> = Result<T, OsdiError>;
