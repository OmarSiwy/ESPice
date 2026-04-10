// build.rs for pisim-linalg
//
// When the `klu` feature is enabled, locate and link the SuiteSparse KLU
// library.  We try three strategies in order:
//
//  1. Environment variable SUITESPARSE_ROOT — the user or CI has set the
//     prefix explicitly.
//  2. pkg-config — the library was installed system-wide.
//  3. Well-known nix store prefix hard-coded from CI — this is the fallback
//     for the NixOS dev-shell used by PiSIM.
//
// If none of the strategies succeeds, we print a warning and the build
// continues without KLU (the `klu` feature will be a no-op stub).

fn main() {
    #[cfg(feature = "klu")]
    link_klu();
}

#[cfg(feature = "klu")]
fn link_klu() {
    // Strategy 1: explicit env var.
    if let Ok(root) = std::env::var("SUITESPARSE_ROOT") {
        println!("cargo:rustc-link-search=native={root}/lib");
        println!("cargo:rustc-link-lib=dylib=klu");
        println!("cargo:rustc-link-lib=dylib=amd");
        println!("cargo:rustc-link-lib=dylib=colamd");
        println!("cargo:rustc-link-lib=dylib=btf");
        println!("cargo:rustc-link-lib=dylib=suitesparseconfig");
        return;
    }

    // Strategy 2: pkg-config.
    if try_pkg_config() {
        return;
    }

    // Strategy 3: scan common nix store paths.
    if try_nix_store() {
        return;
    }

    // No KLU found — emit a warning but do not fail the build.
    // The `klu` feature flag guards all actual uses; callers will get a
    // runtime "KLU not available" error via the stub in klu.rs.
    println!("cargo:warning=KLU library not found. The `klu` feature will be a no-op stub.");
}

#[cfg(feature = "klu")]
fn try_pkg_config() -> bool {
    // pkg_config crate is only available if declared as a build-dependency.
    // We avoid that dep here and invoke pkg-config directly as a process.
    use std::process::Command;
    let out = Command::new("pkg-config")
        .args(["--libs", "klu"])
        .output();
    if let Ok(o) = out {
        if o.status.success() {
            let flags = String::from_utf8_lossy(&o.stdout);
            for flag in flags.split_whitespace() {
                if let Some(path) = flag.strip_prefix("-L") {
                    println!("cargo:rustc-link-search=native={path}");
                } else if let Some(lib) = flag.strip_prefix("-l") {
                    println!("cargo:rustc-link-lib=dylib={lib}");
                }
            }
            return true;
        }
    }
    false
}

#[cfg(feature = "klu")]
fn try_nix_store() -> bool {
    use std::path::Path;

    // Walk /nix/store looking for a suitesparse directory that contains
    // libklu.so.  We match on the directory name prefix to avoid depending on
    // a specific hash.
    let nix_store = Path::new("/nix/store");
    if !nix_store.exists() {
        return false;
    }

    let read_dir = match std::fs::read_dir(nix_store) {
        Ok(d) => d,
        Err(_) => return false,
    };

    for entry in read_dir.flatten() {
        let name = entry.file_name();
        let name_str = name.to_string_lossy();
        // Match e.g. "v6g910bld1arrq6gpy6pv5ivnjp69m5r-suitesparse-5.13.0"
        if !name_str.contains("suitesparse") {
            continue;
        }
        let lib_dir = entry.path().join("lib");
        let klu_so = lib_dir.join("libklu.so");
        if klu_so.exists() {
            let lib_path = lib_dir.to_string_lossy().to_string();
            println!("cargo:rustc-link-search=native={lib_path}");
            println!("cargo:rustc-link-lib=dylib=klu");
            println!("cargo:rustc-link-lib=dylib=amd");
            println!("cargo:rustc-link-lib=dylib=colamd");
            println!("cargo:rustc-link-lib=dylib=btf");
            println!("cargo:rustc-link-lib=dylib=suitesparseconfig");
            return true;
        }
    }
    false
}
