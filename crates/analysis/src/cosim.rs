//! Verilator / SystemVerilog co-simulation bridge.
//!
//! Phase 4.2 of the BigOSpice mixed-signal plan.  We do **not** bundle, link,
//! redistribute, or wrap Verilator's source code in any way; instead we treat
//! the user's `verilator --cc design.v --build -j` *output* (a `libdesign.so`
//! shared object) as a black box and dispatch into it via `libloading`.
//!
//! ## Public API summary
//!
//! ```text
//! VerilatorModel        — RAII wrapper around a loaded `.so`
//! VerilatorSymbols      — function-pointer table resolved at load time
//! DCosim                — `d_cosim` device exposing the model as digital nodes
//! ClockMode             — clock-driven vs continuous-assignment
//! DpiBridge             — DPI-C callback registry
//! ```
//!
//! All submodule content is inlined here (clock_mode, loader, d_cosim, dpi)
//! to keep the flat-file layout consistent with the rest of the analysis crate.

// ---------------------------------------------------------------------------
// clock_mode
// ---------------------------------------------------------------------------

pub mod clock_mode {
    //! Clock-driven vs continuous-assignment dispatch mode for `d_cosim`.
    //!
    //! In **clock-driven** mode the Verilator model is `eval()`-ed only when a
    //! designated clock node sees a rising edge; in **continuous** mode it is
    //! `eval()`-ed every timestep so purely combinational designs can react to
    //! input changes between clocks.

    use crate::digital::DigNodeIdx;

    /// Configuration for the clock node in clock-driven mode.
    #[derive(Debug, Clone, Copy)]
    pub struct ClockSpec {
        /// Digital node carrying the clock signal.
        pub node: DigNodeIdx,
        /// Period [s] of the clock — informational, used by waveform generators.
        pub period: f64,
    }

    impl ClockSpec {
        pub fn new(node: DigNodeIdx, period: f64) -> Self {
            Self { node, period }
        }
    }

    /// How the `d_cosim` device decides to evaluate the wrapped model.
    #[derive(Debug, Clone, Copy)]
    pub enum ClockMode {
        /// Re-evaluate every transient timestep (combinational designs).
        Continuous,
        /// Re-evaluate only on rising edges of the clock node.
        ClockDriven(ClockSpec),
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use crate::digital::DigNodeIdx;

        #[test]
        fn clock_spec_construction() {
            let cs = ClockSpec::new(DigNodeIdx::new(7), 10e-9);
            assert_eq!(cs.node, DigNodeIdx::new(7));
            assert!((cs.period - 10e-9).abs() < 1e-18);
        }
    }
}

// ---------------------------------------------------------------------------
// loader
// ---------------------------------------------------------------------------

pub mod loader {
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
    //! integration shim.  Defaults follow the BigOSpice example shim convention:
    //!
    //! ```text
    //!   incspice_verilator_eval
    //!   incspice_verilator_final
    //!   incspice_verilator_set_signal
    //!   incspice_verilator_get_signal
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
                eval: "incspice_verilator_eval".into(),
                final_: "incspice_verilator_final".into(),
                set_signal: "incspice_verilator_set_signal".into(),
                get_signal: "incspice_verilator_get_signal".into(),
            }
        }
    }

    // Function-pointer typedefs matching the C-ABI shim convention.
    //
    //   extern "C" void incspice_verilator_eval(void* ctx);
    //   extern "C" void incspice_verilator_set_signal(void* ctx, const char* name, uint64_t v);
    //   extern "C" uint64_t incspice_verilator_get_signal(void* ctx, const char* name);
    //
    // The opaque `void* ctx` is the Verilated top-module instance.
    type EvalFn = unsafe extern "C" fn(*mut std::ffi::c_void);
    type FinalFn = unsafe extern "C" fn(*mut std::ffi::c_void);
    type SetSignalFn =
        unsafe extern "C" fn(*mut std::ffi::c_void, *const std::os::raw::c_char, u64);
    type GetSignalFn =
        unsafe extern "C" fn(*mut std::ffi::c_void, *const std::os::raw::c_char) -> u64;
    type CtorFn = unsafe extern "C" fn() -> *mut std::ffi::c_void;

    const CTOR_SYMBOL: &str = "incspice_verilator_new";

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
        /// Load a Verilator shared object from `path` using the default symbol table.
        pub fn load(path: &Path) -> Result<Self, CosimError> {
            Self::load_with_symbols(path, &VerilatorSymbols::default())
        }

        /// Load a Verilator shared object from `path` using a custom symbol table.
        pub fn load_with_symbols(
            path: &Path,
            syms: &VerilatorSymbols,
        ) -> Result<Self, CosimError> {
            // SAFETY: Loading an arbitrary shared library is intrinsically unsafe.
            let lib =
                unsafe { Library::new(path) }.map_err(|source| CosimError::Open {
                    path: path.display().to_string(),
                    source,
                })?;

            // SAFETY: All `Symbol::get` lookups assert the C signatures of the
            // resolved entry points.  The signatures must match the conventions
            // documented above this struct.
            let (eval, final_, set_signal, get_signal, ctor): (
                EvalFn,
                FinalFn,
                SetSignalFn,
                GetSignalFn,
                CtorFn,
            ) = unsafe {
                let eval_sym: Symbol<EvalFn> =
                    lib.get(syms.eval.as_bytes())
                        .map_err(|source| CosimError::MissingSymbol {
                            symbol: syms.eval.clone(),
                            source,
                        })?;
                let final_sym: Symbol<FinalFn> =
                    lib.get(syms.final_.as_bytes())
                        .map_err(|source| CosimError::MissingSymbol {
                            symbol: syms.final_.clone(),
                            source,
                        })?;
                let set_sym: Symbol<SetSignalFn> =
                    lib.get(syms.set_signal.as_bytes()).map_err(|source| {
                        CosimError::MissingSymbol {
                            symbol: syms.set_signal.clone(),
                            source,
                        }
                    })?;
                let get_sym: Symbol<GetSignalFn> =
                    lib.get(syms.get_signal.as_bytes()).map_err(|source| {
                        CosimError::MissingSymbol {
                            symbol: syms.get_signal.clone(),
                            source,
                        }
                    })?;
                let ctor_sym: Symbol<CtorFn> =
                    lib.get(CTOR_SYMBOL.as_bytes())
                        .map_err(|source| CosimError::MissingSymbol {
                            symbol: CTOR_SYMBOL.into(),
                            source,
                        })?;
                (*eval_sym, *final_sym, *set_sym, *get_sym, *ctor_sym)
            };

            // SAFETY: The constructor was resolved above; calling it must produce
            // a valid opaque handle or null.
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
            let cname =
                CString::new(name).map_err(|_| CosimError::InvalidPortName(name.into()))?;
            // SAFETY: `cname` lives until the end of the call.
            unsafe { (self.set_signal)(self.ctx, cname.as_ptr(), value) };
            Ok(())
        }

        /// Read an output port by name.
        pub fn get_signal(&mut self, name: &str) -> Result<u64, CosimError> {
            let cname =
                CString::new(name).map_err(|_| CosimError::InvalidPortName(name.into()))?;
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
            let bad = CString::new("with\0nul");
            assert!(bad.is_err());
        }
    }
}

// ---------------------------------------------------------------------------
// d_cosim
// ---------------------------------------------------------------------------

pub mod d_cosim {
    //! `d_cosim` device — wraps a loaded Verilator model and exposes its ports as
    //! digital nodes that can be driven from / sampled by the digital engine.
    //!
    //! Each transient timestep, the digital event runtime calls `DCosim::tick(t,
    //! digital_state, queue)` which:
    //!
    //! 1. Pushes the latest digital state of every input port into the model
    //!    via `VerilatorModel::set_signal`.
    //! 2. Calls `VerilatorModel::eval()`.
    //! 3. Reads each output port via `get_signal` and emits a digital event into
    //!    the queue if the value changed.

    use crate::digital::{DigNodeIdx, DigState, EventQueue, Strength};

    use super::clock_mode::{ClockMode, ClockSpec};
    use super::loader::{CosimError, VerilatorModel};

    /// Direction of a `d_cosim` port.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub enum PortDirection {
        Input,
        Output,
    }

    /// One mapping of a digital node to a Verilator signal name.
    #[derive(Debug, Clone)]
    pub struct DCosimPort {
        pub name: String,
        pub node: DigNodeIdx,
        pub dir: PortDirection,
        pub width: u8, // 1..=64
        /// For outputs: the last value we observed (so we can emit edge events).
        pub last_value: u64,
    }

    impl DCosimPort {
        pub fn new(
            name: impl Into<String>,
            node: DigNodeIdx,
            dir: PortDirection,
            width: u8,
        ) -> Self {
            Self {
                name: name.into(),
                node,
                dir,
                width: width.clamp(1, 64),
                last_value: 0,
            }
        }
    }

    /// `d_cosim` device.
    pub struct DCosim {
        pub model: VerilatorModel,
        pub ports: Vec<DCosimPort>,
        pub clock: ClockMode,
        pub last_clock_high: bool,
    }

    impl DCosim {
        pub fn new(model: VerilatorModel, clock: ClockMode) -> Self {
            Self {
                model,
                ports: Vec::new(),
                clock,
                last_clock_high: false,
            }
        }

        /// Register a port.  The order of registration is irrelevant.
        pub fn add_port(&mut self, port: DCosimPort) {
            self.ports.push(port);
        }

        /// Find a port by digital node, returning its index in `ports`.
        pub fn find_port_by_node(&self, node: DigNodeIdx) -> Option<usize> {
            self.ports.iter().position(|p| p.node == node)
        }

        /// One simulation tick.
        ///
        /// * `t`             — current simulation time.
        /// * `digital_state` — current digital state slice indexed by node.
        /// * `queue`         — event queue to emit output transitions into.
        pub fn tick(
            &mut self,
            t: f64,
            digital_state: &[DigState],
            queue: &mut EventQueue,
        ) -> Result<(), CosimError> {
            // 1. Decide whether this tick performs an `eval`.
            let should_eval = match &self.clock {
                ClockMode::Continuous => true,
                ClockMode::ClockDriven(ClockSpec { node, .. }) => {
                    let cur = digital_state
                        .get(node.index())
                        .copied()
                        .map(|s| s.is_one())
                        .unwrap_or(false);
                    let edge = !self.last_clock_high && cur;
                    self.last_clock_high = cur;
                    edge
                }
            };

            if !should_eval {
                return Ok(());
            }

            // 2. Push every input port's current digital level into the model.
            for port in self.ports.iter() {
                if port.dir != PortDirection::Input {
                    continue;
                }
                let st = digital_state
                    .get(port.node.index())
                    .copied()
                    .unwrap_or(DigState::X);
                // Map digital state to a u64.  X / Z map to 0.
                let bit = if st.is_one() { 1u64 } else { 0u64 };
                let mask = if port.width >= 64 {
                    u64::MAX
                } else {
                    (1u64 << port.width) - 1
                };
                let value = bit & mask;
                self.model.set_signal(&port.name, value)?;
            }

            // 3. Step the model.
            self.model.eval();

            // 4. Read outputs; emit events on changes.
            for port in self.ports.iter_mut() {
                if port.dir != PortDirection::Output {
                    continue;
                }
                let v = self.model.get_signal(&port.name)?;
                if v != port.last_value {
                    let new_state = if v & 1 != 0 {
                        DigState::one(Strength::Strong)
                    } else {
                        DigState::zero(Strength::Strong)
                    };
                    queue.schedule(t, port.node, new_state);
                    port.last_value = v;
                }
            }

            Ok(())
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use crate::digital::DigNodeIdx;

        #[test]
        fn port_construction() {
            let p = DCosimPort::new("clk", DigNodeIdx::new(0), PortDirection::Input, 1);
            assert_eq!(p.width, 1);
            assert_eq!(p.dir, PortDirection::Input);
        }

        #[test]
        fn width_clamp() {
            let p = DCosimPort::new("data", DigNodeIdx::new(1), PortDirection::Input, 99);
            assert_eq!(p.width, 64);
        }
    }
}

// ---------------------------------------------------------------------------
// dpi
// ---------------------------------------------------------------------------

pub mod dpi {
    //! DPI-C bridge — registers Rust-side callbacks that SystemVerilog can call
    //! via `import "DPI-C" function ... ;` declarations.
    //!
    //! This module provides the type-safe registry of closures.  The actual
    //! `extern "C"` glue lives in the user's shim because it depends on the
    //! signatures they declared in SystemVerilog.

    use ahash::AHashMap;
    use std::sync::Mutex;

    /// A DPI callback closure.  Takes a node name and returns a `f64`.
    pub type DpiCallback = Box<dyn Fn(&str) -> f64 + Send + 'static>;

    /// Thread-safe registry of DPI callbacks.
    pub struct DpiBridge {
        table: Mutex<AHashMap<String, DpiCallback>>,
    }

    impl DpiBridge {
        pub fn new() -> Self {
            Self {
                table: Mutex::new(AHashMap::new()),
            }
        }

        /// Register a callback under a name.
        pub fn register<F>(&self, name: &str, f: F)
        where
            F: Fn(&str) -> f64 + Send + 'static,
        {
            let mut t = self.table.lock().expect("dpi mutex poisoned");
            t.insert(name.to_string(), Box::new(f));
        }

        /// Invoke a callback by name.  Returns `None` if no such callback is
        /// registered.
        pub fn call(&self, name: &str, arg: &str) -> Option<f64> {
            let t = self.table.lock().expect("dpi mutex poisoned");
            t.get(name).map(|f| f(arg))
        }

        /// Number of registered callbacks.
        pub fn len(&self) -> usize {
            self.table.lock().expect("dpi mutex poisoned").len()
        }

        pub fn is_empty(&self) -> bool {
            self.len() == 0
        }
    }

    impl Default for DpiBridge {
        fn default() -> Self {
            Self::new()
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn register_and_call() {
            let bridge = DpiBridge::new();
            bridge.register("incspice_get_voltage", |node| match node {
                "vdd" => 3.3,
                "gnd" => 0.0,
                _ => f64::NAN,
            });
            assert_eq!(bridge.call("incspice_get_voltage", "vdd"), Some(3.3));
            assert_eq!(bridge.call("incspice_get_voltage", "gnd"), Some(0.0));
            assert_eq!(bridge.call("missing", "x"), None);
        }
    }
}

// ---------------------------------------------------------------------------
// Re-exports (public API surface of the cosim module)
// ---------------------------------------------------------------------------

pub use clock_mode::{ClockMode, ClockSpec};
pub use d_cosim::{DCosim, DCosimPort, PortDirection};
pub use dpi::{DpiBridge, DpiCallback};
pub use loader::{CosimError, VerilatorModel, VerilatorSymbols};
