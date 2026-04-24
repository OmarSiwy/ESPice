// SPDX-License-Identifier: LGPL-3.0-only
//
// OSDI ABI definitions follow the public OpenVAF OSDI spec; this file
// contains no OpenVAF source code.

//! # `OsdiPlugin` — `dlopen`-based loader for `.osdi` shared objects.
//!
//! `OsdiPlugin::open(path)` does the bare minimum needed to make a model
//! callable from BigOSpice:
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
use std::path::{Path, PathBuf};
use std::sync::Arc;

use libloading::{Library, Symbol};

use super::abi::{
    OSDI_DESCRIPTORS_SYMBOL, OSDI_NUM_DESCRIPTORS_SYMBOL, OSDI_VERSION_MAJOR,
    OSDI_VERSION_MAJOR_SYMBOL, OSDI_VERSION_MINOR, OSDI_VERSION_MINOR_SYMBOL, OsdiDescriptor,
};
use super::{OsdiError, OsdiResult};

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
        let library =
            unsafe { Library::new(path.as_ref().as_os_str()) }.map_err(|e| OsdiError::DlOpen {
                path: path_str.clone(),
                source: e,
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
            let sym: Symbol<*const OsdiDescriptor> =
                library
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
        unsafe { core::slice::from_raw_parts(self.descriptors_ptr.as_ptr(), self.descriptors_len) }
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

#[cfg(test)]
mod tests {
    use super::*;

    // ── helpers ──────────────────────────────────────────────────────────

    /// Return the path of a `libm.so` present on the current system, if any.
    fn find_libm() -> Option<&'static str> {
        const CANDIDATES: &[&str] = &[
            // NixOS
            "/nix/store/xx7cm72qy2c0643cm1ipngd87aqwkcdp-glibc-2.40-66/lib/libm.so.6",
            "/nix/store/xwcrk1jrv4j4rjnqzn6vglyndx439h5h-glibc-2.42-51/lib/libm.so.6",
            // Debian / Ubuntu
            "/lib/x86_64-linux-gnu/libm.so.6",
            // Fedora / RHEL
            "/lib64/libm.so.6",
            // generic fallback
            "/usr/lib/libm.so.6",
            "/lib/libm.so.6",
        ];
        CANDIDATES
            .iter()
            .copied()
            .find(|p| std::path::Path::new(p).exists())
    }

    // ── cstr helper ──────────────────────────────────────────────────────

    #[test]
    fn cstr_helper_strips_nul() {
        assert_eq!(cstr_to_static(b"OSDI_DESCRIPTORS\0"), "OSDI_DESCRIPTORS");
    }

    #[test]
    fn cstr_helper_no_nul_returns_whole_slice() {
        // When there is no NUL byte the helper returns the whole slice as a str.
        assert_eq!(cstr_to_static(b"HELLO"), "HELLO");
    }

    #[test]
    fn cstr_helper_empty_slice() {
        assert_eq!(cstr_to_static(b""), "");
    }

    #[test]
    fn cstr_helper_only_nul() {
        assert_eq!(cstr_to_static(b"\0"), "");
    }

    // ── missing / nonexistent path ────────────────────────────────────────

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

    #[test]
    fn missing_file_is_err_not_panic() {
        // Regression: `open` must never panic on a missing path.
        let result = OsdiPlugin::open("/this/path/absolutely/does/not/exist.osdi");
        assert!(result.is_err(), "expected Err for missing file, got Ok");
    }

    #[test]
    fn missing_file_error_contains_path_fragment() {
        let result = OsdiPlugin::open("/nonexistent/path/to/plugin.so");
        assert!(result.is_err());
        let err_str = result.unwrap_err().to_string();
        // The Display impl for DlOpen includes the path.
        assert!(
            err_str.contains("nonexistent") || err_str.contains("plugin.so"),
            "error message '{err_str}' does not mention the path"
        );
    }

    // ── non-library file ─────────────────────────────────────────────────

    #[test]
    fn not_a_library_is_err_not_panic() {
        // `/etc/hostname` is a plain text file — definitely not a shared object.
        // On any POSIX platform `dlopen` must reject it.
        let result = OsdiPlugin::open("/etc/hostname");
        assert!(result.is_err(), "expected Err when loading a text file, got Ok");
    }

    #[test]
    fn not_a_library_returns_dlopen_error() {
        // `/etc/os-release` is guaranteed to exist on Linux and is not an ELF.
        let result = OsdiPlugin::open("/etc/os-release");
        assert!(result.is_err());
        // The error should be the DlOpen variant (can't even load it).
        assert!(
            matches!(result.unwrap_err(), OsdiError::DlOpen { .. }),
            "expected DlOpen variant for non-ELF file"
        );
    }

    // ── valid .so that lacks OSDI symbols ────────────────────────────────

    #[test]
    fn system_library_without_osdi_symbols_returns_missing_symbol_error() {
        // libm is a valid shared object but exports no OSDI symbols.
        // Depending on how dlopen resolves OSDI_VERSION_MAJOR_SYMBOL, we
        // expect either MissingSymbol or (on some platforms) DlOpen.
        let Some(libm) = find_libm() else {
            // The test is considered a pass if the system has no libm in a
            // known location — the important thing is we don't panic.
            return;
        };

        let result = OsdiPlugin::open(libm);
        assert!(
            result.is_err(),
            "loading libm (which has no OSDI symbols) should fail"
        );
        // Must not be a panic — the Err path is sufficient.
        match result.unwrap_err() {
            OsdiError::DlOpen { .. } | OsdiError::MissingSymbol { .. } => {}
            other => panic!(
                "expected DlOpen or MissingSymbol when loading libm, got {other:?}"
            ),
        }
    }

    #[test]
    fn system_library_error_is_err_not_panic() {
        // Belt-and-suspenders: confirm no panic regardless of error variant.
        if let Some(libm) = find_libm() {
            let result = OsdiPlugin::open(libm);
            assert!(result.is_err());
        }
    }

    // ── OsdiError Display messages ────────────────────────────────────────

    #[test]
    fn dlopen_error_display_includes_path_and_source() {
        // We can trigger a DlOpen error reliably by pointing at a missing file.
        let err = OsdiPlugin::open("/no/such/file.osdi").unwrap_err();
        let msg = err.to_string();
        // The template is: "failed to open OSDI plugin {path}: {source}"
        assert!(
            msg.contains("no/such/file.osdi"),
            "DlOpen message missing path: {msg}"
        );
        assert!(
            msg.contains("failed to open OSDI plugin"),
            "DlOpen message missing prefix: {msg}"
        );
    }

    #[test]
    fn version_mismatch_error_display_contains_versions() {
        // Build the error directly — no real plugin needed.
        let err = OsdiError::VersionMismatch {
            path: "/fake/plugin.osdi".to_string(),
            found_major: 1,
            found_minor: 0,
            expected_major: OSDI_VERSION_MAJOR,
            expected_minor: OSDI_VERSION_MINOR,
        };
        let msg = err.to_string();
        assert!(msg.contains("1.0"), "message missing found version: {msg}");
        assert!(
            msg.contains(&format!("{}.{}", OSDI_VERSION_MAJOR, OSDI_VERSION_MINOR)),
            "message missing expected version: {msg}"
        );
        assert!(
            msg.contains("/fake/plugin.osdi"),
            "message missing path: {msg}"
        );
    }

    #[test]
    fn missing_symbol_error_display_includes_symbol_name() {
        let err = OsdiError::MissingSymbol {
            path: "/some/plugin.osdi".to_string(),
            symbol: "OSDI_VERSION_MAJOR",
            source: libloading::Error::IncompatibleSize,
        };
        let msg = err.to_string();
        assert!(
            msg.contains("OSDI_VERSION_MAJOR"),
            "message missing symbol name: {msg}"
        );
        assert!(
            msg.contains("/some/plugin.osdi"),
            "message missing path: {msg}"
        );
    }

    #[test]
    fn init_failed_error_display_includes_name_and_flags() {
        let err = OsdiError::InitFailed {
            name: "bsim4nmos".to_string(),
            flags: 0xDEAD_BEEF,
        };
        let msg = err.to_string();
        assert!(msg.contains("bsim4nmos"), "missing name: {msg}");
        assert!(msg.contains("deadbeef"), "missing flags hex: {msg}");
    }

    #[test]
    fn null_fn_ptr_error_display() {
        let err = OsdiError::NullFunctionPointer {
            name: "diode",
            field: "eval",
        };
        let msg = err.to_string();
        assert!(msg.contains("diode"), "missing descriptor name: {msg}");
        assert!(msg.contains("eval"), "missing field name: {msg}");
    }

    #[test]
    fn voltage_len_mismatch_error_display() {
        let err = OsdiError::VoltageLenMismatch {
            name: "bjt_npn".to_string(),
            expected: 4,
            actual: 3,
        };
        let msg = err.to_string();
        assert!(msg.contains("bjt_npn"), "missing name: {msg}");
        assert!(msg.contains('4'), "missing expected count: {msg}");
        assert!(msg.contains('3'), "missing actual count: {msg}");
    }

    #[test]
    fn instance_out_of_bounds_error_display() {
        let err = OsdiError::InstanceOutOfBounds(99);
        let msg = err.to_string();
        assert!(msg.contains("99"), "missing index: {msg}");
    }

    // ── ABI version constants ─────────────────────────────────────────────

    #[test]
    fn abi_version_constants_match_loader_expectations() {
        // The loader checks `major == OSDI_VERSION_MAJOR` and
        // `minor >= OSDI_VERSION_MINOR`. These constants come from `abi.rs`.
        // If either assertion fires, someone bumped the version without
        // updating the version-check logic.
        assert_eq!(
            OSDI_VERSION_MAJOR, 0,
            "OSDI major version changed; review loader version-check"
        );
        assert!(
            OSDI_VERSION_MINOR >= 3,
            "OSDI minor version regressed below 3"
        );
    }

    #[test]
    fn version_mismatch_fields_are_correct() {
        // Directly inspect the `VersionMismatch` variant fields.
        let err = OsdiError::VersionMismatch {
            path: "test.osdi".to_string(),
            found_major: 99,
            found_minor: 1,
            expected_major: OSDI_VERSION_MAJOR,
            expected_minor: OSDI_VERSION_MINOR,
        };
        match err {
            OsdiError::VersionMismatch {
                found_major,
                found_minor,
                expected_major,
                expected_minor,
                ..
            } => {
                assert_eq!(found_major, 99);
                assert_eq!(found_minor, 1);
                assert_eq!(expected_major, OSDI_VERSION_MAJOR);
                assert_eq!(expected_minor, OSDI_VERSION_MINOR);
            }
            _ => unreachable!(),
        }
    }

    // ── symbol name byte slices ───────────────────────────────────────────

    #[test]
    fn symbol_constants_are_nul_terminated() {
        // `libloading::Library::get` expects a NUL-terminated byte slice.
        // Any symbol constant missing the terminator will cause undefined
        // behaviour. Guard that here.
        for sym in [
            super::super::abi::OSDI_DESCRIPTORS_SYMBOL,
            super::super::abi::OSDI_NUM_DESCRIPTORS_SYMBOL,
            super::super::abi::OSDI_VERSION_MAJOR_SYMBOL,
            super::super::abi::OSDI_VERSION_MINOR_SYMBOL,
        ] {
            assert_eq!(
                sym.last().copied(),
                Some(0),
                "symbol {:?} is not NUL-terminated",
                sym
            );
        }
    }

    #[test]
    fn symbol_constants_are_non_empty_before_nul() {
        for sym in [
            super::super::abi::OSDI_DESCRIPTORS_SYMBOL,
            super::super::abi::OSDI_NUM_DESCRIPTORS_SYMBOL,
            super::super::abi::OSDI_VERSION_MAJOR_SYMBOL,
            super::super::abi::OSDI_VERSION_MINOR_SYMBOL,
        ] {
            // At minimum the byte before the NUL must exist.
            assert!(sym.len() > 1, "symbol is only a NUL byte");
        }
    }

    // ── OsdiError is Send ─────────────────────────────────────────────────

    #[test]
    fn osdi_error_is_send() {
        // Compile-time proof that `OsdiError` can cross thread boundaries.
        fn assert_send<T: Send>() {}
        assert_send::<OsdiError>();
    }
}
