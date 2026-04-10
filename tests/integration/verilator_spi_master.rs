// SPDX-License-Identifier: LGPL-3.0
//
// End-to-end Verilator co-simulation: drive an 8-bit SPI master compiled
// from `tests/integration/fixtures/verilog/spi_master.v` from PiSIM and
// observe its MOSI bitstream + MISO sampling.
//
// The test is `#[ignore]`d by default and skipped at runtime if either
// Verilator or a working host C++ toolchain is unavailable; run it via
//
//   cargo test --test verilator_spi_master --release \
//       -- --include-ignored --nocapture
//
// On a clean tree the first invocation builds
//
//   target/cosim/spi_master/libspi_master.so
//
// using the canonical PiSIM shim (see `pisim_shim.cpp` next to the
// Verilog source).  Subsequent invocations reuse the cached `.so`.

use std::path::{Path, PathBuf};
use std::process::Command;

use pisim_cosim::VerilatorModel;

const TX_BYTE: u8 = 0x55;
const MISO_BYTE: u8 = 0xAA;

/// Locate (and build, if necessary) the `libspi_master.so` shared object
/// produced by Verilator + the PiSIM C-ABI shim.  Returns `None` if the
/// toolchain is unavailable so the caller can skip the test gracefully.
fn build_spi_master_so() -> Option<PathBuf> {
    // ── 1. Resolve fixture paths ────────────────────────────────────────
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let verilog = manifest_dir
        .join("tests/integration/fixtures/verilog/spi_master.v");
    let shim = manifest_dir
        .join("tests/integration/fixtures/verilog/pisim_shim.cpp");
    let out_dir = manifest_dir.join("target/cosim/spi_master");
    let so_path = out_dir.join("libspi_master.so");

    if !verilog.exists() || !shim.exists() {
        eprintln!(
            "skip: missing fixture {} or {}",
            verilog.display(),
            shim.display()
        );
        return None;
    }

    // ── 2. Skip cleanly when verilator is not on PATH ───────────────────
    if which("verilator").is_none() {
        eprintln!("skip: verilator not on PATH");
        return None;
    }
    if which("g++").is_none() {
        eprintln!("skip: g++ not on PATH");
        return None;
    }

    // ── 3. Reuse a cached .so if it is newer than both inputs ───────────
    if so_path.exists() && is_fresh(&so_path, &[&verilog, &shim]) {
        return Some(so_path);
    }

    std::fs::create_dir_all(&out_dir).ok()?;

    // ── 4. Run verilator --cc to generate C++ for the design ────────────
    let verilator_status = Command::new("verilator")
        .args([
            "--cc",
            "--top-module",
            "spi_master",
            "-Wno-fatal",
            "--build",
            "-j",
            "0",
        ])
        .arg(&verilog)
        .current_dir(&out_dir)
        .status();
    match verilator_status {
        Ok(s) if s.success() => {}
        Ok(s) => {
            eprintln!("skip: verilator exited with status {s}");
            return None;
        }
        Err(e) => {
            eprintln!("skip: failed to spawn verilator: {e}");
            return None;
        }
    }

    let obj_dir = out_dir.join("obj_dir");
    if !obj_dir.exists() {
        eprintln!("skip: verilator did not produce {}", obj_dir.display());
        return None;
    }

    // ── 5. Locate verilator's include directory ─────────────────────────
    let verilator_inc = locate_verilator_include().or_else(|| {
        eprintln!("skip: could not locate Verilator include directory");
        None
    })?;

    // ── 6. Compile + link shim + Verilator runtime into a .so ───────────
    let verilated_obj = obj_dir.join("verilated.o");
    let verilated_threads_obj = obj_dir.join("verilated_threads.o");
    let lib_archive = obj_dir.join("Vspi_master__ALL.a");
    if !lib_archive.exists() || !verilated_obj.exists() {
        eprintln!(
            "skip: expected {} and {} after verilator --build",
            lib_archive.display(),
            verilated_obj.display()
        );
        return None;
    }

    let mut gpp = Command::new("g++");
    gpp.args(["-O2", "-fPIC", "-shared", "-std=c++17"])
        .arg("-I").arg(&obj_dir)
        .arg("-I").arg(&verilator_inc)
        .arg("-I").arg(verilator_inc.join("vltstd"))
        .arg("-DVERILATOR=1")
        .arg(&shim)
        // -Wl,--whole-archive forces the linker to keep every symbol from
        // the static archive (Verilator hides the model class behind weak
        // statics that the dynamic loader otherwise discards).
        .arg("-Wl,--whole-archive")
        .arg(&lib_archive)
        .arg("-Wl,--no-whole-archive")
        .arg(&verilated_obj);
    if verilated_threads_obj.exists() {
        gpp.arg(&verilated_threads_obj);
    }
    gpp.arg("-o").arg(&so_path).arg("-lpthread");
    let gpp_status = gpp.status();
    match gpp_status {
        Ok(s) if s.success() => Some(so_path),
        Ok(s) => {
            eprintln!("skip: g++ link of shim failed (status {s})");
            None
        }
        Err(e) => {
            eprintln!("skip: failed to spawn g++: {e}");
            None
        }
    }
}

fn is_fresh(target: &Path, deps: &[&PathBuf]) -> bool {
    let target_mtime = match std::fs::metadata(target).and_then(|m| m.modified()) {
        Ok(t) => t,
        Err(_) => return false,
    };
    deps.iter().all(|d| {
        std::fs::metadata(d)
            .and_then(|m| m.modified())
            .map(|t| t <= target_mtime)
            .unwrap_or(false)
    })
}

fn which(prog: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        let candidate = dir.join(prog);
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

fn locate_verilator_include() -> Option<PathBuf> {
    // Ask verilator itself for its root.  Different packagings disagree
    // about whether VERILATOR_ROOT points at the install prefix or directly
    // at `<prefix>/share/verilator`, so we try both.
    let out = Command::new("verilator").arg("--getenv").arg("VERILATOR_ROOT").output().ok()?;
    if !out.status.success() {
        return None;
    }
    let root = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if root.is_empty() {
        return None;
    }
    let root = PathBuf::from(root);
    let candidates = [
        root.join("include"),
        root.join("share/verilator/include"),
    ];
    for c in candidates.iter() {
        if c.is_dir() {
            return Some(c.clone());
        }
    }
    None
}

#[test]
#[ignore = "requires verilator + g++ on PATH; build is slow"]
fn spi_master_drives_mosi_and_samples_miso() {
    let so = match build_spi_master_so() {
        Some(p) => p,
        None => {
            eprintln!(
                "verilator_spi_master: skipping (toolchain or fixture unavailable)"
            );
            return;
        }
    };
    eprintln!("verilator_spi_master: loaded {}", so.display());

    let mut model = VerilatorModel::load(&so).expect("load libspi_master.so");

    // ── 1. Reset for two clk cycles ─────────────────────────────────────
    model.set_signal("rst_n", 0).unwrap();
    model.set_signal("clk", 0).unwrap();
    model.set_signal("start", 0).unwrap();
    model.set_signal("tx_data", 0).unwrap();
    model.set_signal("miso", 0).unwrap();
    model.eval();
    pulse_clk(&mut model);
    pulse_clk(&mut model);
    model.set_signal("rst_n", 1).unwrap();

    // ── 2. Latch tx_data and pulse `start` for one clk ──────────────────
    model.set_signal("tx_data", TX_BYTE as u64).unwrap();
    model.set_signal("start", 1).unwrap();
    pulse_clk(&mut model);
    model.set_signal("start", 0).unwrap();

    // ── 3. Run the transfer.  Two clk cycles per SPI bit, eight bits, +
    //       a few extras for the trailing falling edge that latches rx_data.
    let mut mosi_bits: Vec<u8> = Vec::with_capacity(8);
    let mut miso_idx: u8 = 0;
    let mut last_sclk: u64 = 0;
    let mut max_iter = 64;

    while max_iter > 0 {
        max_iter -= 1;

        // Drive next miso bit BEFORE the rising edge that will sample it.
        // We feed bits MSB-first matching MISO_BYTE.
        if miso_idx < 8 {
            let bit = (MISO_BYTE >> (7 - miso_idx)) & 1;
            model.set_signal("miso", bit as u64).unwrap();
        }

        // Half-period: clk low.
        model.set_signal("clk", 0).unwrap();
        model.eval();

        // Half-period: clk high (rising edge of host clk).
        model.set_signal("clk", 1).unwrap();
        model.eval();

        // Sample sclk + mosi after the host clk edge has propagated.
        let sclk_now = model.get_signal("sclk").unwrap();
        let mosi_now = model.get_signal("mosi").unwrap();

        // On the rising edge of sclk we record the mosi bit (master launches
        // it on the previous falling edge → it is stable at the rising edge).
        if last_sclk == 0 && sclk_now == 1 {
            mosi_bits.push(mosi_now as u8);
            miso_idx = miso_idx.saturating_add(1);
        }
        last_sclk = sclk_now;

        // Stop once busy has dropped after at least 8 sampled bits.
        let busy = model.get_signal("busy").unwrap();
        if busy == 0 && mosi_bits.len() >= 8 {
            break;
        }
    }

    // ── 4. Reconstruct MOSI byte (MSB first) and validate ───────────────
    assert!(
        mosi_bits.len() >= 8,
        "expected at least 8 mosi bits, got {} ({:?})",
        mosi_bits.len(),
        mosi_bits
    );
    let mut mosi_byte: u8 = 0;
    for (i, b) in mosi_bits.iter().take(8).enumerate() {
        mosi_byte |= (b & 1) << (7 - i);
    }
    eprintln!(
        "verilator_spi_master: mosi bits = {:?}  →  byte = 0x{:02X}",
        &mosi_bits[..8],
        mosi_byte
    );
    assert_eq!(
        mosi_byte, TX_BYTE,
        "MOSI bitstream mismatch: got 0x{:02X}, expected 0x{:02X}",
        mosi_byte, TX_BYTE
    );

    // ── 5. Validate the captured rx_data byte ───────────────────────────
    let rx = model.get_signal("rx_data").unwrap() as u8;
    eprintln!("verilator_spi_master: rx_data = 0x{:02X}", rx);
    assert_eq!(
        rx, MISO_BYTE,
        "MISO capture mismatch: got 0x{:02X}, expected 0x{:02X}",
        rx, MISO_BYTE
    );

    // ── 6. CS_n must have returned high after busy dropped ──────────────
    let cs_n = model.get_signal("cs_n").unwrap();
    assert_eq!(cs_n, 1, "cs_n must be deasserted after the transfer ends");
}

/// Toggle the host clock low→high→low to advance one full clk cycle.
fn pulse_clk(model: &mut VerilatorModel) {
    model.set_signal("clk", 0).unwrap();
    model.eval();
    model.set_signal("clk", 1).unwrap();
    model.eval();
}
