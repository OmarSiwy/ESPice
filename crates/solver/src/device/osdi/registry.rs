// SPDX-License-Identifier: LGPL-3.0-only
//
// OSDI ABI definitions follow the public OpenVAF OSDI spec; this file
// contains no OpenVAF source code.

//! # `OsdiRegistry` — runtime registration of OSDI device kinds.
//!
//! Lifecycle:
//!
//! 1. CLI sees `--osdi bsim4.osdi` flag.
//! 2. `OsdiRegistry::load_plugin("bsim4.osdi")` opens the shared object
//!    via [`OsdiPlugin::open`], indexes every descriptor by name, and
//!    keeps the plugin alive in an `Arc<OsdiPlugin>`.
//! 3. The SPICE parser hits a model card whose name matches one of the
//!    registered descriptors. It calls
//!    [`OsdiRegistry::create_instance`] which allocates an
//!    [`OsdiInstance`], runs `setup_instance` + `init_instance`, and
//!    returns a stable [`OsdiInstanceIdx`].
//! 4. The dispatch layer wraps that index in
//!    [`crate::device_kind::OsdiDeviceKind`] and inserts it into the
//!    `DeviceDispatch::Osdi` variant.
//! 5. On every Newton-Raphson iteration the stamper calls
//!    [`OsdiRegistry::evaluate`] with the index + node voltages; the
//!    trampoline handles the rest.
//!
//! All instance state lives in a single `Vec<OsdiInstance>` owned by the
//! registry — DOD: contiguous, indexed by `u32`, no per-device heap
//! pointers in the dispatch enum.

use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;

use incspice_core::ParamMap;

use super::abi::OsdiDescriptor;
use super::device_kind::{OsdiDeviceKind, OsdiInstanceIdx};
use super::instance::OsdiInstance;
use super::loader::OsdiPlugin;
use super::trampoline::OsdiTrampoline;
use super::{OsdiError, OsdiResult};

/// Per-descriptor metadata kept in the registry alongside the loaded
/// plugin.
struct DescriptorEntry {
    /// Index of the owning plugin in `OsdiRegistry::plugins`.
    plugin_idx: u32,
    /// Index of the descriptor inside the plugin's table.
    descriptor_idx: u32,
}

/// Registry of all loaded OSDI plugins + every live instance.
pub struct OsdiRegistry {
    /// Loaded plugins (stable order, never reordered).
    plugins: Vec<Arc<OsdiPlugin>>,
    /// Map from descriptor name -> table index.
    by_name: HashMap<String, DescriptorEntry>,
    /// Live instances (SoA-friendly: one Vec, indexed by `OsdiInstanceIdx`).
    instances: Vec<OsdiInstance>,
    /// Per-instance trampolines (parallel array — same index as `instances`).
    trampolines: Vec<OsdiTrampoline>,
}

impl OsdiRegistry {
    /// Create an empty registry.
    pub fn new() -> Self {
        Self {
            plugins: Vec::new(),
            by_name: HashMap::new(),
            instances: Vec::new(),
            trampolines: Vec::new(),
        }
    }

    /// Load an `.osdi` plugin and index every descriptor it exposes.
    ///
    /// Returns the names of all newly registered descriptors.
    pub fn load_plugin(&mut self, path: impl AsRef<Path>) -> OsdiResult<Vec<String>> {
        let plugin = Arc::new(OsdiPlugin::open(path)?);
        let plugin_idx = self.plugins.len() as u32;

        let mut new_names = Vec::new();
        for (descriptor_idx, (name, _desc)) in plugin.iter_named().enumerate() {
            let entry = DescriptorEntry {
                plugin_idx,
                descriptor_idx: descriptor_idx as u32,
            };
            self.by_name.insert(name.to_string(), entry);
            new_names.push(name.to_string());
        }
        self.plugins.push(plugin);
        Ok(new_names)
    }

    /// Number of registered plugins.
    pub fn num_plugins(&self) -> usize {
        self.plugins.len()
    }

    /// Number of registered descriptors (across all plugins).
    pub fn num_descriptors(&self) -> usize {
        self.by_name.len()
    }

    /// Number of live instances.
    pub fn num_instances(&self) -> usize {
        self.instances.len()
    }

    /// Look up a descriptor by name.
    pub fn descriptor(&self, name: &str) -> Option<&OsdiDescriptor> {
        let entry = self.by_name.get(name)?;
        let plugin = &self.plugins[entry.plugin_idx as usize];
        plugin.descriptors().get(entry.descriptor_idx as usize)
    }

    /// Create a new device instance for the descriptor named `name`.
    ///
    /// Returns an [`OsdiInstanceIdx`] that can be used to look the
    /// instance up later (and that should be embedded in
    /// `DeviceDispatch::Osdi`).
    pub fn create_instance(
        &mut self,
        name: &str,
        params: &ParamMap,
        temperature: f64,
    ) -> OsdiResult<OsdiInstanceIdx> {
        let entry = self
            .by_name
            .get(name)
            .ok_or_else(|| OsdiError::MissingParameter {
                name: name.to_string(),
                param: "<unregistered descriptor>".to_string(),
            })?;
        let plugin = Arc::clone(&self.plugins[entry.plugin_idx as usize]);
        let descriptor: &OsdiDescriptor = plugin
            .descriptors()
            .get(entry.descriptor_idx as usize)
            .expect("descriptor index out of bounds");

        // Allocate the trampoline first (it's pure Rust, can't fail).
        let trampoline = OsdiTrampoline::new(descriptor);

        // Then build the instance — the only fallible step.
        let library = plugin.library_arc();
        let instance = OsdiInstance::new(library, descriptor, params, temperature)?;

        let idx = OsdiInstanceIdx::new(self.instances.len() as u32);
        self.instances.push(instance);
        self.trampolines.push(trampoline);
        Ok(idx)
    }

    /// Build a [`OsdiDeviceKind`] for the given instance.
    pub fn device_kind(&self, idx: OsdiInstanceIdx) -> OsdiResult<OsdiDeviceKind> {
        let instance = self
            .instances
            .get(idx.index())
            .ok_or(OsdiError::InstanceOutOfBounds(idx.index()))?;
        Ok(OsdiDeviceKind::new(
            idx,
            instance.num_terminals() as u8,
            // OSDI tells us about contributions; the trampoline never
            // requires a branch current row in the MNA matrix.
            false,
        ))
    }

    /// Run one full evaluation: write voltages → eval → load Jacobian.
    ///
    /// Returns a borrow of the trampoline so the stamper can read out the
    /// freshly written conductance/residual buffers.
    pub fn evaluate(
        &mut self,
        idx: OsdiInstanceIdx,
        voltages: &[f64],
        time: f64,
        alpha: f64,
    ) -> OsdiResult<&OsdiTrampoline> {
        let i = idx.index();
        if i >= self.instances.len() {
            return Err(OsdiError::InstanceOutOfBounds(i));
        }

        // Split borrows manually so we can borrow `instances[i]` and
        // `trampolines[i]` mutably at the same time.
        let instance: &mut OsdiInstance = &mut self.instances[i];
        let trampoline: &mut OsdiTrampoline = &mut self.trampolines[i];

        let descriptor_ptr = instance.descriptor() as *const OsdiDescriptor;
        // SAFETY: descriptor_ptr is valid as long as `instance` is live.
        let descriptor = unsafe { &*descriptor_ptr };

        trampoline.write_voltages(voltages, descriptor)?;
        trampoline.evaluate(instance, time, alpha)?;
        Ok(&self.trampolines[i])
    }

    /// Borrow a trampoline by index (for reading buffers between calls).
    pub fn trampoline(&self, idx: OsdiInstanceIdx) -> OsdiResult<&OsdiTrampoline> {
        self.trampolines
            .get(idx.index())
            .ok_or(OsdiError::InstanceOutOfBounds(idx.index()))
    }

    /// List the names of every descriptor known to the registry. Useful
    /// for diagnostics and shell completion.
    pub fn known_descriptors(&self) -> Vec<&str> {
        self.by_name.keys().map(|s| s.as_str()).collect()
    }
}

impl Default for OsdiRegistry {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_registry_is_empty() {
        let reg = OsdiRegistry::new();
        assert_eq!(reg.num_plugins(), 0);
        assert_eq!(reg.num_descriptors(), 0);
        assert_eq!(reg.num_instances(), 0);
        assert!(reg.descriptor("anything").is_none());
        assert!(reg.known_descriptors().is_empty());
    }

    #[test]
    fn create_instance_unknown_name_errors() {
        let mut reg = OsdiRegistry::new();
        let err = reg
            .create_instance("nonexistent", &ParamMap::new(), 300.0)
            .unwrap_err();
        match err {
            OsdiError::MissingParameter { name, .. } => {
                assert_eq!(name, "nonexistent");
            }
            other => panic!("expected MissingParameter, got {other:?}"),
        }
    }

    #[test]
    fn out_of_bounds_evaluate_errors() {
        let mut reg = OsdiRegistry::new();
        let err = reg
            .evaluate(OsdiInstanceIdx::new(42), &[], 0.0, 0.0)
            .unwrap_err();
        assert!(matches!(err, OsdiError::InstanceOutOfBounds(42)));
    }
}
