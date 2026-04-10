// SPDX-License-Identifier: LGPL-3.0-only
//
// OSDI ABI definitions follow the public OpenVAF OSDI spec; this file
// contains no OpenVAF source code.

//! # `OsdiPlugin` — `dlopen`-based loader for `.osdi` shared objects.
//!
//! `OsdiPlugin::open(path)` does the bare minimum needed to make a model
//! callable from PiSIM:
//!
//! 1. `dlopen` the file via [`libloading::Library::new`].
//! 2. Resolve `OSDI_VERSION_MAJOR`/`MINOR`, validate against
//!    [`OSDI_VERSION_MAJOR`]/[`OSDI_VERSION_MINOR`].
//! 3. Resolve `OSDI_NUM_DESCRIPTORS` and `OSDI_DESCRIPTORS`.
//! 4. Wrap the descriptor pointer (still owned by the plugin) and return.
//!
//! The plugin lives as long as the `OsdiPlugin` value — when the value is
//! dropped, `libloading` calls `dlclose`, which invalidates the descriptor
//! pointer. Any [`OsdiInstance`] referencing the plugin must be dropped
//! first.
//!
//! [`OsdiInstance`]: crate::instance::OsdiInstance

use core::ffi::CStr;
use core::ptr::NonNull;
use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use libloading::{Library, Symbol};

use crate::abi::{
    OsdiDescriptor, OSDI_DESCRIPTORS_SYMBOL, OSDI_NUM_DESCRIPTORS_SYMBOL,
    OSDI_VERSION_MAJOR, OSDI_VERSION_MAJOR_SYMBOL, OSDI_VERSION_MINOR, OSDI_VERSION_MINOR_SYMBOL,
};
use crate::{OsdiError, OsdiResult};

/// A loaded OSDI shared object plus a slice view of its descriptor table.
///
/// Wrap in an `Arc` if you need to share between the registry and live
/// instances. The internal layout is intentionally tiny (heap pointer,
/// path, slice descriptor) so cloning the `Arc` is one refcount bump.
#[allow(missing_debug_implementations)]
pub struct OsdiPlugin {
    /// Path the plugin was loaded from (kept for diagnostics).
    path: PathBuf,
    /// Live `dlopen` handle. Dropped last.
    library: Arc<Library>,
    /// Pointer + length view of the plugin's `OSDI_DESCRIPTORS` table. The
    /// memory is owned by `library` and lives until `library` is dropped.
    descriptors_ptr: NonNull<OsdiDescriptor>,
    descriptors_len: usize,
    /// Cached version, after validation.
    version: (u32, u32),
}

// SAFETY: An `OsdiPlugin` only exposes immutable descriptor data after
// construction; mutating any descriptor is impossible through this API.
// The wrapped `Arc<Library>` is itself `Send + Sync` (libloading guarantees
// this on dlopen-backed platforms), and the descriptor pointer is read-only
// for the entire lifetime of the plugin.
unsafe impl Send for OsdiPlugin {}
unsafe impl Sync for OsdiPlugin {}

impl core::fmt::Debug for OsdiPlugin {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("OsdiPlugin")
            .field("path", &self.path)
            .field("version", &self.version)
            .field("num_descriptors", &self.descriptors_len)
            .finish_non_exhaustive()
    }
}

impl OsdiPlugin {
    /// Open an `.osdi` shared object via `dlopen`.
    ///
    /// The file must be a position-independent executable produced by
    /// `openvaf model.va -o model.osdi`. We resolve the documented OSDI
    /// symbols, validate the major/minor version, and capture a slice view
    /// of the descriptor table.
    pub fn open(path: impl AsRef<Path>) -> OsdiResult<Self> {
        let path_buf = path.as_ref().to_path_buf();
        let path_str = path_buf.display().to_string();

        // SAFETY: `Library::new` is `unsafe` because dlopen runs the
        // shared object's `_init` constructors which can do anything. We
        // assume the user has audited the .osdi file (it's compiled from
        // their own .va source). The library handle is then owned by us
        // and freed at drop.
        let library = unsafe { Library::new(path.as_ref().as_os_str()) }.map_err(|e| {
            OsdiError::DlOpen {
                path: path_str.clone(),
                source: e,
            }
        })?;

        let library = Arc::new(library);

        // ── version handshake ────────────────────────────────────────
        let major = read_scalar::<u32>(&library, OSDI_VERSION_MAJOR_SYMBOL, &path_str)?;
        let minor = read_scalar::<u32>(&library, OSDI_VERSION_MINOR_SYMBOL, &path_str)?;
        if major != OSDI_VERSION_MAJOR || minor < OSDI_VERSION_MINOR {
            return Err(OsdiError::VersionMismatch {
                path: path_str,
                found_major: major,
                found_minor: minor,
                expected_major: OSDI_VERSION_MAJOR,
                expected_minor: OSDI_VERSION_MINOR,
            });
        }

        // ── descriptor table ─────────────────────────────────────────
        let num_descriptors =
            read_scalar::<u32>(&library, OSDI_NUM_DESCRIPTORS_SYMBOL, &path_str)? as usize;

        // SAFETY: `OSDI_DESCRIPTORS` is documented as a contiguous array
        // of `OsdiDescriptor` of length `OSDI_NUM_DESCRIPTORS`. We resolve
        // a pointer-to-the-first-element symbol exactly as the spec
        // dictates. The slice we manufacture borrows from the plugin's
        // BSS/RDATA, which lives until `dlclose`.
        let descriptors_ptr: *const OsdiDescriptor = unsafe {
            let sym: Symbol<*const OsdiDescriptor> = library
                .get(OSDI_DESCRIPTORS_SYMBOL)
                .map_err(|e| OsdiError::MissingSymbol {
                    path: path_str.clone(),
                    symbol: "OSDI_DESCRIPTORS",
                    source: e,
                })?;
            *sym
        };

        let nn = NonNull::new(descriptors_ptr as *mut OsdiDescriptor).ok_or(
            OsdiError::MissingSymbol {
                path: path_str,
                symbol: "OSDI_DESCRIPTORS (null)",
                source: libloading::Error::IncompatibleSize,
            },
        )?;

        Ok(Self {
            path: path_buf,
            library,
            descriptors_ptr: nn,
            descriptors_len: num_descriptors,
            version: (major, minor),
        })
    }

    /// Path the plugin was loaded from.
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// `(major, minor)` version reported by the plugin.
    pub fn version(&self) -> (u32, u32) {
        self.version
    }

    /// Number of device descriptors in the plugin.
    pub fn num_descriptors(&self) -> usize {
        self.descriptors_len
    }

    /// Borrow the descriptor table as a slice. The slice's lifetime is
    /// bound to `&self`, which is bound to the live `Arc<Library>`.
    pub fn descriptors(&self) -> &[OsdiDescriptor] {
        // SAFETY: `descriptors_ptr` was validated non-null in `open`, and
        // `descriptors_len` came from the plugin's `OSDI_NUM_DESCRIPTORS`
        // export. The plugin owns the underlying memory; it's read-only
        // and lives at least as long as `self`.
        unsafe {
            core::slice::from_raw_parts(self.descriptors_ptr.as_ptr(), self.descriptors_len)
        }
    }

    /// Find a descriptor by its `name` field. Linear scan — descriptor
    /// counts are tiny (typically 1–4 per plugin).
    pub fn find_descriptor(&self, name: &str) -> Option<&OsdiDescriptor> {
        self.descriptors().iter().find(|desc| {
            // SAFETY: `desc.name` is a NUL-terminated UTF-8 string owned
            // by the plugin's RDATA, valid for the lifetime of `self`.
            let cs = unsafe { CStr::from_ptr(desc.name) };
            cs.to_str().map(|s| s == name).unwrap_or(false)
        })
    }

    /// Iterator over `(name, descriptor)` pairs.
    pub fn iter_named(&self) -> impl Iterator<Item = (&str, &OsdiDescriptor)> {
        self.descriptors().iter().filter_map(|desc| {
            // SAFETY: see `find_descriptor`.
            let cs = unsafe { CStr::from_ptr(desc.name) };
            cs.to_str().ok().map(|s| (s, desc))
        })
    }

    /// Clone the inner `Arc<Library>` so that an `OsdiInstance` can keep
    /// the plugin alive even if the registry forgets about it.
    pub(crate) fn library_arc(&self) -> Arc<Library> {
        Arc::clone(&self.library)
    }
}

/// Read a `T: Copy` scalar exported as a global by the plugin.
fn read_scalar<T: Copy>(library: &Library, symbol: &[u8], path: &str) -> OsdiResult<T> {
    // SAFETY: We resolve the symbol as a pointer to `T` and dereference
    // it once. The OSDI ABI documents these as plain global `uint32_t`
    // values, so the type tag `T = u32` matches the on-disk layout. Any
    // mismatch is a bug in the plugin and a clear ABI violation.
    unsafe {
        let sym: Symbol<*const T> = library.get(symbol).map_err(|e| OsdiError::MissingSymbol {
            path: path.to_string(),
            symbol: cstr_to_static(symbol),
            source: e,
        })?;
        Ok(*(*sym))
    }
}

/// Convert a NUL-terminated `&[u8]` to a `&'static str` (the symbol names
/// in this file are all string literals).
fn cstr_to_static(bytes: &[u8]) -> &'static str {
    // We only ever pass our own `b"..."` literals here, so leaking the
    // bytes-without-NUL slice as `'static` is sound: the literals live in
    // `.rodata` for the entire program lifetime.
    let no_nul = bytes
        .iter()
        .position(|b| *b == 0)
        .map(|p| &bytes[..p])
        .unwrap_or(bytes);
    // SAFETY: every caller passes ASCII string literals.
    unsafe { core::str::from_utf8_unchecked(core::mem::transmute::<&[u8], &'static [u8]>(no_nul)) }
}

/// Convenience: load every `.osdi` file in a directory.
pub fn load_directory(dir: impl AsRef<OsStr>) -> std::io::Result<Vec<OsdiPlugin>> {
    let dir_path = Path::new(dir.as_ref());
    let mut plugins = Vec::new();
    for entry in std::fs::read_dir(dir_path)? {
        let entry = entry?;
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) == Some("osdi") {
            if let Ok(plugin) = OsdiPlugin::open(&path) {
                plugins.push(plugin);
            }
        }
    }
    Ok(plugins)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cstr_helper_strips_nul() {
        assert_eq!(cstr_to_static(b"OSDI_DESCRIPTORS\0"), "OSDI_DESCRIPTORS");
    }

    #[test]
    fn missing_file_returns_dlopen_error() {
        let err = OsdiPlugin::open("/nonexistent/path/does_not_exist.osdi").unwrap_err();
        match err {
            OsdiError::DlOpen { path, .. } => {
                assert!(path.contains("does_not_exist.osdi"));
            }
            other => panic!("expected DlOpen error, got {other:?}"),
        }
    }
}
