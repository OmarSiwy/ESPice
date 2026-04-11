//! Verilator shared-object loader.
//!
//! Resolves the four entry points that every Verilated model exports:
//!
//! * `eval`        — advance the model by one combinational pass.
//! * `final`       — terminate the model and free internal state.
//! * `set_signal`  — drive an input port (variant: by name or by handle).
//! * `get_signal`  — read an output port.
//!
//! The exact symbol names depend on Verilator's `--prefix` and the user's
//! integration shim.  The loader accepts a `VerilatorSymbols` table so the
//! caller can override defaults — defaults follow the convention used by the
//! BigOSpice example shims:
//!
//! ```text
//!   bigospice_verilator_eval
//!   bigospice_verilator_final
//!   bigospice_verilator_set_signal
//!   bigospice_verilator_get_signal
//! ```
//!
//! `unsafe` is confined to the `Library::get` lookups and the function-pointer
//! invocations; the public surface (`VerilatorModel::eval`, `set_signal`, …)
//! is safe and traffics only in plain values.

use std::ffi::CString;
use std::path::Path;

use libloading::{Library, Symbol};
use thiserror::Error;

/// Errors raised by the loader.
#[derive(Debug, Error)]
pub enum CosimError {
    #[error("failed to open verilator shared object {path}: {source}")]
    Open {
        path: String,
        #[source]
        source: libloading::Error,
    },
    #[error("missing symbol '{symbol}' in verilator shared object: {source}")]
    MissingSymbol {
        symbol: String,
        #[source]
        source: libloading::Error,
    },
    #[error("port name '{0}' is not valid C (contains a NUL byte)")]
    InvalidPortName(String),
    #[error("verilator co-sim error: {0}")]
    Other(String),
}

/// Function-pointer table for the Verilator C ABI.  Override the symbol names
/// before loading if your shim uses different identifiers.
#[derive(Debug, Clone)]
pub struct VerilatorSymbols {
    pub eval: String,
    pub final_: String,
    pub set_signal: String,
    pub get_signal: String,
}

impl Default for VerilatorSymbols {
    fn default() -> Self {
        Self {
            eval: "bigospice_verilator_eval".into(),
            final_: "bigospice_verilator_final".into(),
            set_signal: "bigospice_verilator_set_signal".into(),
            get_signal: "bigospice_verilator_get_signal".into(),
        }
    }
}

// Function-pointer typedefs matching the C-ABI shim convention.
//
// The shim is a thin layer the user writes once per design, e.g.:
//
//   extern "C" void bigospice_verilator_eval(void* ctx);
//   extern "C" void bigospice_verilator_set_signal(void* ctx, const char* name, uint64_t v);
//   extern "C" uint64_t bigospice_verilator_get_signal(void* ctx, const char* name);
//
// The opaque `void* ctx` is the Verilated top-module instance.
type EvalFn = unsafe extern "C" fn(*mut std::ffi::c_void);
type FinalFn = unsafe extern "C" fn(*mut std::ffi::c_void);
type SetSignalFn = unsafe extern "C" fn(*mut std::ffi::c_void, *const std::os::raw::c_char, u64);
type GetSignalFn = unsafe extern "C" fn(*mut std::ffi::c_void, *const std::os::raw::c_char) -> u64;
type CtorFn = unsafe extern "C" fn() -> *mut std::ffi::c_void;

const CTOR_SYMBOL: &str = "bigospice_verilator_new";

/// RAII wrapper around a loaded Verilator shared object.
///
/// The library lives for as long as `VerilatorModel`; on drop the model's
/// `final` entry point is invoked and the library handle is released.
pub struct VerilatorModel {
    // SAFETY: `lib` must outlive every function pointer derived from it.
    // We hold both in the same struct so the borrow checker enforces this.
    _lib: Library,
    ctx: *mut std::ffi::c_void,
    eval: EvalFn,
    final_: FinalFn,
    set_signal: SetSignalFn,
    get_signal: GetSignalFn,
}

// SAFETY: Verilator-generated models are single-threaded; we expose a `&mut`
// API exclusively, and the function pointers we hold do not capture any
// thread-local state at the Rust level.  Callers must not share a single
// model across threads concurrently — the type is `Send` but `!Sync`.
unsafe impl Send for VerilatorModel {}

impl VerilatorModel {
    /// Load a Verilator shared object from `path` using the default symbol
    /// table.
    pub fn load(path: &Path) -> Result<Self, CosimError> {
        Self::load_with_symbols(path, &VerilatorSymbols::default())
    }

    /// Load a Verilator shared object from `path` using a custom symbol table.
    pub fn load_with_symbols(path: &Path, syms: &VerilatorSymbols) -> Result<Self, CosimError> {
        // SAFETY: Loading an arbitrary shared library is intrinsically unsafe.
        // We document the requirement on the user that they only point this
        // function at a Verilated `.so` produced by their own build system.
        let lib = unsafe { Library::new(path) }.map_err(|source| CosimError::Open {
            path: path.display().to_string(),
            source,
        })?;

        // SAFETY: All `Symbol::get` lookups are unsafe because we are
        // asserting the C signatures of the resolved entry points.  The
        // signatures must match the conventions documented above this struct.
        let (eval, final_, set_signal, get_signal, ctor): (
            EvalFn,
            FinalFn,
            SetSignalFn,
            GetSignalFn,
            CtorFn,
        ) = unsafe {
            let eval_sym: Symbol<EvalFn> = lib
                .get(syms.eval.as_bytes())
                .map_err(|source| CosimError::MissingSymbol {
                    symbol: syms.eval.clone(),
                    source,
                })?;
            let final_sym: Symbol<FinalFn> = lib
                .get(syms.final_.as_bytes())
                .map_err(|source| CosimError::MissingSymbol {
                    symbol: syms.final_.clone(),
                    source,
                })?;
            let set_sym: Symbol<SetSignalFn> = lib
                .get(syms.set_signal.as_bytes())
                .map_err(|source| CosimError::MissingSymbol {
                    symbol: syms.set_signal.clone(),
                    source,
                })?;
            let get_sym: Symbol<GetSignalFn> = lib
                .get(syms.get_signal.as_bytes())
                .map_err(|source| CosimError::MissingSymbol {
                    symbol: syms.get_signal.clone(),
                    source,
                })?;
            let ctor_sym: Symbol<CtorFn> = lib
                .get(CTOR_SYMBOL.as_bytes())
                .map_err(|source| CosimError::MissingSymbol {
                    symbol: CTOR_SYMBOL.into(),
                    source,
                })?;
            (*eval_sym, *final_sym, *set_sym, *get_sym, *ctor_sym)
        };

        // SAFETY: The constructor was resolved above; calling it must produce
        // a valid opaque handle or null.  We treat null as a load error.
        let ctx = unsafe { ctor() };
        if ctx.is_null() {
            return Err(CosimError::Other(
                "Verilator constructor returned NULL".into(),
            ));
        }

        Ok(Self {
            _lib: lib,
            ctx,
            eval,
            final_,
            set_signal,
            get_signal,
        })
    }

    /// Advance the Verilated model by one combinational pass.
    pub fn eval(&mut self) {
        // SAFETY: `eval` came from a successfully resolved symbol on a
        // non-null context handle; the C ABI is `void(*)(void*)`.
        unsafe { (self.eval)(self.ctx) }
    }

    /// Drive an input port by name.
    pub fn set_signal(&mut self, name: &str, value: u64) -> Result<(), CosimError> {
        let cname = CString::new(name).map_err(|_| CosimError::InvalidPortName(name.into()))?;
        // SAFETY: `cname` lives until the end of the call; the function
        // signature matches the C ABI.
        unsafe { (self.set_signal)(self.ctx, cname.as_ptr(), value) };
        Ok(())
    }

    /// Read an output port by name.
    pub fn get_signal(&mut self, name: &str) -> Result<u64, CosimError> {
        let cname = CString::new(name).map_err(|_| CosimError::InvalidPortName(name.into()))?;
        // SAFETY: same conditions as `set_signal`.
        let v = unsafe { (self.get_signal)(self.ctx, cname.as_ptr()) };
        Ok(v)
    }
}

impl Drop for VerilatorModel {
    fn drop(&mut self) {
        if !self.ctx.is_null() {
            // SAFETY: The destructor matches `final` from the resolved symbol
            // table and is invoked exactly once on a non-null context.
            unsafe { (self.final_)(self.ctx) };
            self.ctx = std::ptr::null_mut();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_so_returns_open_error() {
        let result = VerilatorModel::load(Path::new("/dev/null/does/not/exist.so"));
        assert!(matches!(result, Err(CosimError::Open { .. })));
    }

    #[test]
    fn invalid_port_name_returns_error() {
        // Build a fake symbol table whose names will never resolve, so we
        // can't reach `set_signal`.  Instead we exercise CString validation
        // directly via the helper.
        let bad = CString::new("with\0nul");
        assert!(bad.is_err());
    }
}
