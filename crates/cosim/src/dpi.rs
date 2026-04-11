//! DPI-C bridge — registers Rust-side callbacks that SystemVerilog can call
//! via `import "DPI-C" function ... ;` declarations.
//!
//! The pattern follows ngspice's `d_cosim` and Verilator's DPI shim:
//!
//! 1. The user writes a tiny C wrapper exposing each DPI export they want to
//!    invoke from BigOSpice (e.g. `bigospice_get_voltage(const char* node)`).
//! 2. The wrapper forwards into a function pointer set by Rust at startup
//!    via `DpiBridge::register`.
//! 3. BigOSpice's analog state is read through the closure.
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
        bridge.register("bigospice_get_voltage", |node| match node {
            "vdd" => 3.3,
            "gnd" => 0.0,
            _ => f64::NAN,
        });
        assert_eq!(bridge.call("bigospice_get_voltage", "vdd"), Some(3.3));
        assert_eq!(bridge.call("bigospice_get_voltage", "gnd"), Some(0.0));
        assert_eq!(bridge.call("missing", "x"), None);
    }
}
