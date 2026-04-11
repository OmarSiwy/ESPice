# Wave 1 – Agent 1: flake.nix Optional Simulators

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split flake.nix into a minimal `devShells.default` (Rust toolchain only) and a `devShells.full` that also provides ngspice, xyce-parallel, and a from-source VACASK build.

**Architecture:** Extract the common build inputs into a shared `let` binding. Derive `devShells.full` by extending `devShells.default.buildInputs`. Build VACASK using `pkgs.stdenv.mkDerivation` with `pkgs.fetchFromGitea` — it uses cmake and links against SuiteSparse (already in the flake). The `.#full` shell exports `BIGOSPICE_HAVE_SIMS=1` so benches/tests can gate on simulator availability.

**Tech Stack:** Nix flakes, `pkgs.fetchFromGitea`, `pkgs.stdenv.mkDerivation`, cmake, C++, SuiteSparse/KLU.

---

### Task 1: Discover the VACASK commit hash

**Files:**
- No file changes — discovery step only

- [ ] **Step 1: Fetch the latest VACASK commit hash from Codeberg**

```bash
curl -s "https://codeberg.org/api/v1/repos/arpadbuermen/VACASK/branches/main" \
  | grep -o '"sha":"[^"]*"' | head -1
```

Note the SHA (e.g. `a3f9c12...`). You will use it in Task 2.

- [ ] **Step 2: Compute the nix hash for that commit**

```bash
nix-prefetch-url --unpack \
  "https://codeberg.org/arpadbuermen/VACASK/archive/<SHA>.tar.gz"
```

Replace `<SHA>` with the value from Step 1. Note the `sha256-...` SRI hash printed at the end. You will use it in Task 2.

---

### Task 2: Write the VACASK nix derivation

**Files:**
- Modify: `flake.nix`

- [ ] **Step 1: Add the `vacaskPkg` derivation inside the `let` block in `flake.nix`, before the `in` keyword**

Open `flake.nix`. Find the `let` block (line ~22). Add this after the `rustNightly` binding, replacing `<SHA>` and `<SRI_HASH>` with the values from Task 1:

```nix
vacaskPkg = pkgs.stdenv.mkDerivation rec {
  pname = "vacask";
  version = "unstable-2026";

  src = pkgs.fetchFromGitea {
    domain = "codeberg.org";
    owner = "arpadbuermen";
    repo = "VACASK";
    rev = "<SHA>";
    hash = "<SRI_HASH>";
  };

  nativeBuildInputs = with pkgs; [
    cmake
    pkg-config
  ];

  buildInputs = with pkgs; [
    suitesparse   # provides KLU
    openblas
  ];

  cmakeFlags = [
    "-DCMAKE_BUILD_TYPE=Release"
  ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    # VACASK produces a 'vacask' binary in the build directory
    cp vacask $out/bin/vacask
    runHook postInstall
  '';

  meta = {
    description = "VACASK – Verilog-A Circuit Analysis Kernel";
    homepage = "https://codeberg.org/arpadbuermen/VACASK";
    license = pkgs.lib.licenses.gpl2Plus;
    platforms = pkgs.lib.platforms.linux ++ pkgs.lib.platforms.darwin;
  };
};
```

- [ ] **Step 2: Verify the derivation evaluates without error**

```bash
cd /home/omare/Documents/Projects/Active/BigOSpice
nix eval .#packages.x86_64-linux.default --no-build 2>&1 | head -20
```

Expected: No evaluation error. (Build errors are OK at this stage — we're checking syntax only.)

---

### Task 3: Split devShells.default and devShells.full

**Files:**
- Modify: `flake.nix`

- [ ] **Step 1: Extract shared build inputs into a `commonInputs` binding**

In the `let` block, add after `vacaskPkg`:

```nix
commonInputs = with pkgs; [
  rustNightly
  pkg-config
  openssl

  # Linker
  mold-wrapped
  clang

  # Linear algebra
  suitesparse
  openblas
  lapack

  # Build tools
  cmake
  gnumake

  # Dev tools
  cargo-watch
  cargo-nextest
  cargo-tarpaulin
  cargo-flamegraph
  cargo-expand

  # Benchmarks
  hyperfine

  # Mixed-signal cosimulation
  verilator
  verible
];
```

- [ ] **Step 2: Replace the existing `devShells.default` with the new split shells**

Replace the entire `devShells.default = pkgs.mkShell { ... };` block with:

```nix
devShells.default = pkgs.mkShell {
  buildInputs = commonInputs;

  shellHook = ''
    export RUST_BACKTRACE=1
    export RUST_LOG=bigospice=debug
    echo "BigOSpice dev shell — nightly Rust $(rustc --version) + mold linker"
    echo "Tip: use 'nix develop .#full' to get ngspice, xyce, and VACASK"
  '';

  SUITESPARSE_DIR = "${pkgs.suitesparse}";
  OPENBLAS_DIR = "${pkgs.openblas}";
};

devShells.full = pkgs.mkShell {
  buildInputs = commonInputs ++ [
    pkgs.ngspice
    pkgs.xyce-parallel
    vacaskPkg
  ];

  shellHook = ''
    export RUST_BACKTRACE=1
    export RUST_LOG=bigospice=debug
    export BIGOSPICE_HAVE_SIMS=1
    echo "BigOSpice FULL dev shell — nightly Rust $(rustc --version)"
    echo "Simulators: ngspice $(ngspice --version 2>&1 | head -1)"
    echo "            xyce    $(xyce --version 2>&1 | head -1)"
    echo "            vacask  $(vacask --version 2>&1 | head -1 || echo 'available')"
  '';

  SUITESPARSE_DIR = "${pkgs.suitesparse}";
  OPENBLAS_DIR = "${pkgs.openblas}";
};
```

- [ ] **Step 3: Verify the flake evaluates**

```bash
nix flake check --no-build 2>&1 | head -30
```

Expected: Warnings only (about missing system deps). No evaluation errors.

---

### Task 4: Verify both shells work

**Files:**
- No changes

- [ ] **Step 1: Enter the minimal shell and confirm no simulators present**

```bash
nix develop --command bash -c '
  echo "BIGOSPICE_HAVE_SIMS=${BIGOSPICE_HAVE_SIMS:-unset}"
  which ngspice 2>/dev/null && echo "FAIL: ngspice present in default shell" || echo "OK: ngspice absent"
  which xyce 2>/dev/null && echo "FAIL: xyce present in default shell" || echo "OK: xyce absent"
  rustc --version
'
```

Expected output:
```
BIGOSPICE_HAVE_SIMS=unset
OK: ngspice absent
OK: xyce absent
rustc 1.XX.X-nightly ...
```

- [ ] **Step 2: Enter the full shell and confirm simulators present**

```bash
nix develop .#full --command bash -c '
  echo "BIGOSPICE_HAVE_SIMS=${BIGOSPICE_HAVE_SIMS}"
  which ngspice && echo "OK: ngspice found"
  which xyce && echo "OK: xyce found"
  which vacask && echo "OK: vacask found"
' 2>&1 | grep -E "OK:|FAIL:|HAVE_SIMS"
```

Expected: All three `OK:` lines and `BIGOSPICE_HAVE_SIMS=1`.

---

### Task 5: Commit

**Files:**
- Commit: `flake.nix`, `flake.lock` (updated by nix)

- [ ] **Step 1: Update flake.lock**

```bash
nix flake update 2>&1 | tail -5
```

- [ ] **Step 2: Commit**

```bash
git add flake.nix flake.lock
git commit -m "feat(flake): split devShells — default minimal, .#full adds ngspice/xyce/VACASK

VACASK built from source via pkgs.fetchFromGitea + cmake.
BIGOSPICE_HAVE_SIMS=1 exported in .#full shell for bench/test gating.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```
