// SPDX-License-Identifier: LGPL-3.0-only
//
// OSDI ABI definitions follow the public OpenVAF OSDI spec; this file
// contains no OpenVAF source code.

//! # `OsdiInstance` — heap-allocated per-device state owned by Rust.
//!
//! The OSDI ABI says: "the simulator allocates `instance_size` bytes of
//! zeroed memory and passes the pointer to every function as the handle".
//! That allocation lives here. We:
//!
//! - Allocate `instance_size` bytes via the global allocator (aligned to
//!   `f64`, which is enough for every BSIM/PSP/HiSIM model the OpenVAF
//!   compiler emits — those models only contain `double`/`int`/`bool`).
//! - Hand the raw pointer to the plugin's `setup_instance` /
//!   `init_instance` / `eval` / `load_*` functions.
//! - Free the buffer in `Drop`.
//!
//! The buffer must outlive every call into the plugin, hence the
//! `Box<[u8]>` field instead of borrowing.
//!
//! Per-instance buffers are kept in a contiguous `Vec` inside
//! [`crate::registry::OsdiRegistry`] for SoA cache locality.

use core::ffi::{c_void, CStr};
use core::ptr::NonNull;
use std::sync::Arc;

use libloading::Library;
use pisim_core::ParamMap;

use crate::abi::{
    OsdiBool, OsdiDescriptor, OsdiInitInfo, OsdiSimInfo, OsdiSimParas,
};
use crate::{OsdiError, OsdiResult};

/// One live OSDI device instance.
///
/// Internally this is a `Box<[u8]>` of `descriptor.instance_size` bytes,
/// pinned by the heap allocation. We additionally hold an `Arc<Library>`
/// so the plugin's code stays mapped at least as long as the instance.
pub struct OsdiInstance {
    /// Owning library handle, kept alive for the duration of the instance.
    _library: Arc<Library>,
    /// Pointer back to the descriptor (still owned by the plugin).
    descriptor: *const OsdiDescriptor,
    /// Heap allocation handed to plugin functions as the `handle` argument.
    instance_buf: Box<[u8]>,
    /// Optional model-card buffer (some descriptors share state).
    model_buf: Option<Box<[u8]>>,
    /// Cached number of terminals (read once from the descriptor).
    num_terminals: u32,
    /// Cached display name.
    name: String,
    /// Whether `init_instance` has been called yet.
    initialised: bool,
}

// SAFETY: The instance buffer is exclusively owned by `Self`, and every
// public method takes `&mut self` so concurrent access is impossible
// without explicit synchronisation by the caller. The library handle is
// itself `Send + Sync` on dlopen platforms.
unsafe impl Send for OsdiInstance {}

impl OsdiInstance {
    /// Construct a new instance for `descriptor`. Allocates `instance_size`
    /// (and `model_size`) bytes of zeroed memory.
    ///
    /// `setup_instance` and `init_instance` are called immediately so the
    /// resulting instance is ready for `eval` calls.
    pub fn new(
        library: Arc<Library>,
        descriptor: &OsdiDescriptor,
        params: &ParamMap,
        temperature: f64,
    ) -> OsdiResult<Self> {
        let name = descriptor_name(descriptor);

        let instance_buf =
            vec![0u8; descriptor.instance_size as usize].into_boxed_slice();

        let model_buf = if descriptor.model_size > 0 {
            Some(vec![0u8; descriptor.model_size as usize].into_boxed_slice())
        } else {
            None
        };

        let mut this = Self {
            _library: library,
            descriptor: descriptor as *const _,
            instance_buf,
            model_buf,
            num_terminals: descriptor.num_terminals,
            name,
            initialised: false,
        };

        this.write_params(params)?;
        this.run_setup(temperature)?;
        this.run_init(temperature)?;

        Ok(this)
    }

    /// Number of external terminals.
    #[inline]
    pub fn num_terminals(&self) -> u32 {
        self.num_terminals
    }

    /// Display name (descriptor `name` field).
    pub fn name(&self) -> &str {
        &self.name
    }

    /// Borrow the descriptor.
    pub fn descriptor(&self) -> &OsdiDescriptor {
        // SAFETY: `self.descriptor` was constructed from a `&OsdiDescriptor`
        // owned by the plugin's RDATA. We keep `Arc<Library>` alive for
        // the entire lifetime of `self`, so the descriptor remains valid.
        unsafe { &*self.descriptor }
    }

    /// Mutable raw pointer to the per-instance buffer (for trampoline use).
    #[inline]
    pub(crate) fn handle_ptr(&mut self) -> *mut c_void {
        self.instance_buf.as_mut_ptr() as *mut c_void
    }

    /// Mutable raw pointer to the model-card buffer (or null).
    #[inline]
    pub(crate) fn model_ptr(&mut self) -> *mut c_void {
        self.model_buf
            .as_mut()
            .map(|b| b.as_mut_ptr() as *mut c_void)
            .unwrap_or(core::ptr::null_mut())
    }

    /// Write user-provided parameters into the OSDI parameter slots.
    ///
    /// The OSDI ABI stores parameters at fixed byte offsets inside the
    /// per-instance buffer (the `OsdiParamOpvar.offset` field). We do a
    /// simple linear scan: descriptor parameter counts are bounded
    /// (~50 for BSIM4) and this only runs once per instance creation.
    fn write_params(&mut self, params: &ParamMap) -> OsdiResult<()> {
        let descriptor = unsafe { &*self.descriptor };
        if descriptor.num_params == 0 {
            return Ok(());
        }

        // SAFETY: `descriptor.params` is documented as a contiguous array
        // of `num_params` entries, owned by the plugin's RDATA.
        let param_slice = unsafe {
            core::slice::from_raw_parts(descriptor.params, descriptor.num_params as usize)
        };

        for p in param_slice {
            // SAFETY: `p.name` is a NUL-terminated UTF-8 string in the
            // plugin's RDATA, owned for the lifetime of the library.
            let name_cstr = unsafe { CStr::from_ptr(p.name) };
            let Ok(name) = name_cstr.to_str() else {
                continue;
            };

            if let Some(value) = params.get(name) {
                // OSDI parameter slots are `f64`-sized for the common
                // numeric case. We bounds-check the offset before writing.
                let offset = p.offset as usize;
                let end = offset + core::mem::size_of::<f64>();
                if end > self.instance_buf.len() {
                    return Err(OsdiError::MissingParameter {
                        name: self.name.clone(),
                        param: name.to_string(),
                    });
                }
                // SAFETY: Bounds checked above. Writing an `f64` at an
                // 8-byte-aligned offset (OSDI guarantees this) is sound.
                unsafe {
                    let dst = self.instance_buf.as_mut_ptr().add(offset) as *mut f64;
                    dst.write_unaligned(value);
                }
            }
        }
        Ok(())
    }

    fn run_setup(&mut self, temperature: f64) -> OsdiResult<()> {
        let descriptor = unsafe { &*self.descriptor };
        let mut sim_info = empty_sim_info(temperature);

        // Optional: setup_model first.
        if let Some(setup_model) = descriptor.setup_model {
            let model_handle = self.model_ptr();
            if !model_handle.is_null() {
                // SAFETY: `setup_model` comes from the plugin's function
                // table; we pass it the model buffer we own + a sim_info
                // we own. Both outlive the call.
                let info = unsafe { setup_model(model_handle, &mut sim_info) };
                check_init_info(&self.name, &info)?;
            }
        }

        if let Some(setup_instance) = descriptor.setup_instance {
            let model_handle = self.model_ptr();
            let inst_handle = self.handle_ptr();
            // SAFETY: same justification as setup_model. The handles point
            // to live, exclusively-owned heap allocations.
            let info = unsafe { setup_instance(inst_handle, model_handle, &mut sim_info) };
            check_init_info(&self.name, &info)?;
        }

        Ok(())
    }

    fn run_init(&mut self, temperature: f64) -> OsdiResult<()> {
        let descriptor = unsafe { &*self.descriptor };
        let Some(init_instance) = descriptor.init_instance else {
            // Some plugins don't need explicit init.
            self.initialised = true;
            return Ok(());
        };

        let mut sim_info = empty_sim_info(temperature);
        let handle = self.handle_ptr();

        // SAFETY: `init_instance` is the documented OSDI entry point. We
        // pass the heap-owned handle, a stack-owned `OsdiSimInfo` (which
        // outlives the call), and the temperature scalar.
        let info = unsafe { init_instance(handle, &mut sim_info, temperature) };
        check_init_info(&self.name, &info)?;

        self.initialised = true;
        Ok(())
    }
}

impl Drop for OsdiInstance {
    fn drop(&mut self) {
        // The Box<[u8]> buffers are freed automatically. The Arc<Library>
        // is decremented; if it reaches zero, libloading calls dlclose,
        // which will run the plugin's destructors.
    }
}

/// Build a zero-initialised `OsdiSimInfo` with just the temperature set.
fn empty_sim_info(_temperature: f64) -> OsdiSimInfo {
    OsdiSimInfo {
        paras: OsdiSimParas {
            names: core::ptr::null_mut(),
            vals: core::ptr::null_mut(),
            names_str: core::ptr::null_mut(),
            vals_str: core::ptr::null_mut(),
        },
        abstime: 0.0,
        prev_solve: core::ptr::null_mut(),
        prev_state: core::ptr::null_mut(),
        next_state: core::ptr::null_mut(),
        flags: 0,
    }
}

/// Translate the descriptor name pointer to an owned `String`.
fn descriptor_name(descriptor: &OsdiDescriptor) -> String {
    if descriptor.name.is_null() {
        return String::from("<unnamed>");
    }
    // SAFETY: descriptor.name is documented NUL-terminated UTF-8 and lives
    // as long as the plugin.
    unsafe { CStr::from_ptr(descriptor.name) }
        .to_string_lossy()
        .into_owned()
}

/// Convert an `OsdiInitInfo` non-zero error into an `OsdiError::InitFailed`.
fn check_init_info(name: &str, info: &OsdiInitInfo) -> OsdiResult<()> {
    // The OSDI spec defines low bits of `flags` as severity. Anything
    // non-zero is treated as an error here; the trampoline can later
    // demote warnings.
    if info.flags & 0xFFFF != 0 {
        return Err(OsdiError::InitFailed {
            name: name.to_string(),
            flags: info.flags,
        });
    }
    Ok(())
}

/// Helper used by integration tests: pretend to construct an instance
/// from a non-null pointer + size without going through the plugin.
#[cfg(test)]
pub fn synthetic_instance_for_tests(
    library: Arc<Library>,
    descriptor: &OsdiDescriptor,
) -> OsdiInstance {
    let buf = vec![0u8; descriptor.instance_size.max(8) as usize].into_boxed_slice();
    OsdiInstance {
        _library: library,
        descriptor: descriptor as *const _,
        instance_buf: buf,
        model_buf: None,
        num_terminals: descriptor.num_terminals,
        name: descriptor_name(descriptor),
        initialised: true,
    }
}

/// Public helper used by [`crate::trampoline`] to keep a non-null
/// invariant on the handle pointer.
#[allow(dead_code)]
pub(crate) fn handle_nonnull(instance: &mut OsdiInstance) -> Option<NonNull<c_void>> {
    NonNull::new(instance.handle_ptr())
}

/// Cast helper used by `OsdiInstance` consumers.
#[inline]
#[allow(dead_code)]
pub(crate) fn osdi_bool(b: bool) -> OsdiBool {
    if b {
        1
    } else {
        0
    }
}
